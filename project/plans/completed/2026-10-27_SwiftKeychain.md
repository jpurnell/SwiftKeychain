# Design Proposal: a Keychain credential store, as its own package

**Date:** 2026-10-27
**Status:** Implemented, released as 0.1.0 on 2026-10-27 (§17 records what changed while building). Open questions decided by the user 2026-10-27 (§15): named SwiftKeychain; command-line
tools use the login keychain; public repository, proprietary licence. Stack Map gap #7 ("Keychain credential store", `sec`
layer, capability `keychain`). The user decided it is its own package, not part of
swift-cli-kit-auth.
**Author:** Claude (session with Justin Purnell)

## 1. Objective

A small Swift package that keeps tokens and keys in the Apple Keychain, with conformances for the
storage protocols the stack already defines. Apps pick it; the libraries never depend on it.

## 2. Motivation

Three packages define where secrets go, and none can put them in the Keychain:

| Protocol | Where | What it holds | Today |
|---|---|---|---|
| `OAuthClientStorage` | swift-oauth `SwiftOAuthClient/ClientStorage.swift:20` | `StoredCredential` (access + rotating refresh token, expiries, scope) per `ConnectionID` | in memory, or `EncryptedFileClientStorage`, whose key "should come from the Keychain" (:40-48) and nothing supplies |
| `TokenCache` | swift-cli-kit-auth `TokenCache.swift:17` | one bearer token | `FileTokenCache`; its doc expects "a Keychain-backed cache is a later conformance" |
| `SealingKey`, `Pepper` | SwiftIdentity `Credential/SealingKey.swift:18`, `Pepper.swift:16` | 32-byte server keys | owner-only files via `KeyFile.read` |

Keychain code already exists in four places, each written for one app:
SwiftMCPClient's `CredentialStoreKey` (the best: add-then-update, `AfterFirstUnlockThisDeviceOnly`,
`OSStatus` carried in the error, a protocol seam, 9 tests), FleetWatch's `KeychainTokenStore` and
`KeychainSecretStore` (the second sets no accessibility class), and a read-only helper in
IconquerCLI. The Stack Map gap says "promote it if so"; this promotes SwiftMCPClient's.

## 3. Proposed Architecture

```
SwiftKeychain
├── SwiftKeychain          (Foundation + Security only)
│     KeychainAccess protocol ── SystemKeychain (SecItem*) / in-memory for tests
│     KeychainItem (service, account, accessibility, synchronizable, accessGroup)
│     KeychainKey.loadOrCreate (32-byte keys: never replaced if malformed)
├── SwiftKeychainOAuth     (+ swift-oauth)            OAuthClientStorage conformance
└── SwiftKeychainTokenCache (+ swift-cli-kit-auth)     TokenCache conformance
```

- **Three products, one package.** An app that uses only swift-oauth doesn't resolve
  swift-cli-kit-auth. The adapters live here, not in the consumers, so swift-oauth, SwiftIdentity
  and swift-cli-kit-auth stay free of it and keep building on Linux, which their CI requires.
- **Apple platforms only.** The package declares macOS 14, iOS 17, visionOS 1, matching its
  consumers. On Linux it doesn't build; Linux apps keep the file stores.
- **One item per secret, written whole.** `store` is add, then update on `errSecDuplicateItem`, as
  SwiftMCPClient does. A rotated refresh token replaces the item in one call; there is no
  read-modify-write window.
- **Device-only by default.** `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not
  synchronizable. See §12 for why OAuth credentials must never sync.
- **SwiftIdentity's keys:** `KeychainKey.loadOrCreate` returns `Data`; SwiftIdentity would need a
  `SealingKey(data:)`/`Pepper(data:)` initializer to use it. That is a SwiftIdentity change,
  proposed separately (§14), not part of this package.

## 4. API Surface

```swift
// SwiftKeychain
public protocol KeychainAccess: Sendable {
    func data(for item: KeychainItem) throws(KeychainError) -> Data?
    func store(_ data: Data, as item: KeychainItem) throws(KeychainError)
    func delete(_ item: KeychainItem) throws(KeychainError)          // absent is not an error
    func accounts(service: String) throws(KeychainError) -> [String]  // attributes only, no data
}

public struct KeychainItem: Sendable, Hashable {
    public var service: String
    public var account: String
    public var accessibility: Accessibility = .afterFirstUnlockThisDeviceOnly
    public var synchronizable: Bool = false
    public var accessGroup: String? = nil
    public enum Accessibility: Sendable { case whenUnlockedThisDeviceOnly, afterFirstUnlockThisDeviceOnly,
                                                  whenUnlocked, afterFirstUnlock }
}

public struct SystemKeychain: KeychainAccess {
    public init(dataProtection: Bool = true)   // see §15 Q2
}

public enum KeychainError: Error, Equatable, Sendable {
    case locked                    // errSecInteractionNotAllowed
    case missingEntitlement        // errSecMissingEntitlement (-34018)
    case malformed(String)         // stored bytes aren't what the caller expects
    case status(OSStatus)          // anything else, carried, never swallowed
}

public enum KeychainKey {
    /// A 32-byte key: read, or created and stored before it is returned. A stored item of the
    /// wrong size throws `.malformed` rather than being replaced.
    public static func loadOrCreate(_ item: KeychainItem, using: some KeychainAccess) throws(KeychainError) -> Data
}

// SwiftKeychainOAuth
public actor KeychainClientStorage: OAuthClientStorage {
    public init(service: String, keychain: some KeychainAccess = SystemKeychain())
}

// SwiftKeychainTokenCache
public struct KeychainTokenCache: TokenCache {
    public init(service: String, account: String, keychain: some KeychainAccess = SystemKeychain())
}
```

- `KeychainClientStorage` files each credential under `account = ConnectionID` encoded as JSON
  (it is `Codable`), so `connections()` decodes accounts rather than parsing
  `tenant/provider[/account]`, which breaks on a `/` in any field.
- `synchronizable: true` with a `…ThisDeviceOnly` class is refused at `store` as `.malformed`
  rather than passed to the Keychain, which would reject it with an opaque status.

## 6. Constraints & Compliance

- No secret in a log, an error message or a description: `KeychainError` carries statuses and
  item names, never data. `os.Logger` with `.private` for accounts.
- The gate's `security.insecure-keychain` rule refuses `Always` classes; `Accessibility` doesn't
  offer them.
- swift-crypto is not needed: keys are `Data`; swift-oauth's `SymmetricKey(data:)` takes them.

## 7. Source & API Compatibility

New package, 0.1.0. No change to any consumer. swift-cli-kit-auth's `TokenCache` and swift-oauth's
`OAuthClientStorage` are used as they are.

## 9. Dependencies

`SwiftKeychain`: none beyond Foundation and Security. `SwiftKeychainOAuth`: swift-oauth
(`from: 1.0.0-beta.9`). `SwiftKeychainTokenCache`: swift-cli-kit-auth (`from: 0.4.0`).

## 10. Test Strategy

- **Logic through an in-memory `KeychainAccess`**, as SwiftMCPClient does: round-trips; replace
  on second store; delete of absent; `connections()` with a `/` in a tenant; a malformed key
  refused, not replaced; `synchronizable` + device-only refused; a `.locked` read surfacing as an
  error, not as "signed out".
- **The real Keychain, on macOS, in a separate test target** that uses a unique service per run
  and deletes what it wrote. It runs locally. On CI's unsigned runner the data-protection
  keychain returns `missingEntitlement`; the target asserts that mapping there, so CI still
  exercises `SystemKeychain`'s status handling.
- The in-memory accessor is public (apps test against it too), so no symbol exists only for tests.

## 12. Adversarial Review

- **Synced refresh tokens are a revocation hazard.** Two devices holding one rotating refresh
  token both refresh; the provider sees reuse and revokes the family (swift-oauth keeps
  `previousRefreshToken` for exactly this). So `KeychainClientStorage` always uses device-only
  items and doesn't expose `synchronizable`. "Shared across devices where appropriate" means
  keys and long-lived tokens an app chooses to sync through `KeychainItem`, never OAuth sessions.
- **A locked device must not look signed out.** `errSecInteractionNotAllowed` throws `.locked`;
  returning `nil` would make the app start a fresh sign-in and overwrite a good credential.
- **Unsigned command-line tools** can't use the data-protection keychain. `SystemKeychain(dataProtection: false)`
  uses the login keychain, which may prompt. See §15 Q2.
- **Reinstall on iOS** leaves Keychain items behind. A stale credential is refused by the
  provider and cleared by the existing flows (`RememberedToken` clears a token that doesn't
  admit); no reinstall detection is added.

## 13. Alternatives Considered

- **Put the conformances in each consumer.** Rejected: swift-oauth and SwiftIdentity build on
  Linux in CI, and swift-cli-kit-auth's rule is that it depends on swift-cli-kit and SwiftIdentity
  only.
- **Encrypted file plus one Keychain key** (SwiftMCPClient's pattern) for OAuth instead of one
  item per credential. Kept available (`KeychainKey` + `EncryptedFileClientStorage`), not the
  default: it adds a file to lose and a second failure mode for no gain on Apple platforms.
- **A third-party Keychain library.** Rejected per the "build our own" rule; the surface is small.

## 14. Future Directions

`SecAccessControl` with biometry (user presence) for step-up; SwiftIdentity `SealingKey(data:)` and
`Pepper(data:)`; promoting SwiftMCPClient and FleetWatch onto this package.

## 15. Open Questions (decided 2026-10-27)

1. **Name:** SwiftKeychain, with modules `SwiftKeychain`, `SwiftKeychainOAuth` and
   `SwiftKeychainTokenCache`, matching SwiftIdentity and SwiftCLIKit.
2. **Command-line tools:** pass `SystemKeychain(dataProtection: false)` and use the login
   keychain, which works unsigned; macOS may ask once for access. The README says so.
3. **Repository:** public, proprietary licence, as swift-cli-kit-auth.

## 16. Documentation Strategy

DocC for every public symbol; a README with the three products, the device-only rule for OAuth,
and the CLI caveat; a guide article on choosing accessibility and sync.

## 17. Decided while building

- **§3 was wrong about resolution.** It said an app using one adapter "doesn't resolve" the other
  package. SwiftPM resolves every package-level dependency, so naming swift-oauth and
  swift-cli-kit-auth here would have made every app download both graphs. The adapters now sit
  behind package traits, `OAuth` and `CLIAuth`, off by default. Verified in a scratch package:
  a dependency named only by a disabled trait is neither resolved nor downloaded, and enabling the
  trait resolves it. The user chose off-by-default and asked for the gate to learn traits, so
  the gate and CI build with them on (quality-gate-swift `feat/swiftpm-traits`).
- **One module, not three.** With traits, the adapters compile into `SwiftKeychain` under
  `#if OAuth` and `#if CLIAuth`. An app writes `import SwiftKeychain` and enables the trait.
- **The data-protection keychain and an unsigned process.** Storing is refused as
  `missingEntitlement`, as expected. Reading is not refused: the system answers "not found", so
  it reads as `nil`. A tool misconfigured this way sees nothing stored and fails loudly at its
  first save; it can't overwrite a credential it can't see. Recorded in a test and on
  `SystemKeychain`.
- **The login keychain from the test runner** stores, reads, replaces, lists and deletes without a
  prompt for items the same process created, so the contract tests run against it as well as the
  in-memory store.
