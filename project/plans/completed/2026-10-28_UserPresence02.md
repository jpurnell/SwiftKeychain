# Design Proposal: SwiftKeychain 0.2.0 — user presence, and keys for SwiftIdentity

**Status:** Proposed 2026-10-28. Scope from the 0.1.0 roadmap's "Later"; the user asked for 0.2 on 2026-10-28.

## 1. Objective

1. An item can require the person to be present (Touch ID, Face ID, Optic ID, or the device passcode or
   account password) before it is read.
2. SwiftIdentity's server keys, `SealingKey` and `Pepper`, can be kept in the Keychain instead of an
   owner-only file.

## 2. Motivation

- **Step-up.** A credential whose use should be a deliberate act, such as a signing key or an admin
  token, is readable by any code running as the person once the device is unlocked. User presence
  makes each read ask. The 0.1.0 proposal deferred it (§14).
- **SwiftIdentity's keys live in files.** `SealingKey(contentsOf:)` and `Pepper(contentsOf:)` read
  32-byte owner-only files. NIST SP 800-63B-4 §3.1.1.2 says the pepper "SHOULD be stored and used
  within a hardware-protected area"; `Pepper`'s DocC says plainly that a file isn't. On an Apple
  platform the data-protection keychain is closer: encrypted under keys the Secure Enclave guards,
  and not readable from a disk image or a backup when the item is device-only. It is still not
  "used within" hardware: the key is in process memory while in use. The docs will say so.

## 3. Proposed Architecture

### 3.1 User presence (SwiftKeychain)

`KeychainItem` gains `requiresUserPresence: Bool` (default `false`) and `presencePrompt: String?`.

- `SystemKeychain` builds a `SecAccessControl` with `.userPresence` and the item's accessibility class,
  and sends `kSecAttrAccessControl` instead of `kSecAttrAccessible` (the two are exclusive).
- Reads of such an item pass an `LAContext` (`kSecUseAuthenticationContext`) whose `localizedReason`
  is the prompt. That is the supported replacement for the deprecated `kSecUseOperationPrompt`.
- **Validation** (`KeychainItem.validate`, already the place for "an item no store can hold"):
  - `requiresUserPresence` with `synchronizable` is refused: items under access control don't sync.
  - `requiresUserPresence` with no `presencePrompt` is refused: macOS shows the reason in the sheet,
    and an empty reason is a prompt the person can't judge.
- **macOS login keychain:** access control needs the data-protection keychain.
  `SystemKeychain(dataProtection: false)` refuses an item that requires presence, with
  `.malformed`, before calling the Keychain, rather than storing it without the protection asked for.
- **Errors:** two new `KeychainError` cases.
  - `.cancelled`: the person dismissed the prompt (`errSecUserCanceled`). Not "signed out", and not
    to be retried in a loop.
  - `.authenticationFailed`: they tried and failed (`errSecAuthFailed`).
  Adding cases to a public enum breaks exhaustive switches, which is why this is 0.2.0, not 0.1.2.
- **Writes** don't prompt: adding an item doesn't need the person. Replacing one (`SecItemUpdate`)
  can, so `store` over an existing presence item may prompt. The DocC will say which calls may ask.

### 3.2 `InMemoryKeychain`

It keeps the Keychain's rules, so it applies the same validation. Apps need to test the "they
cancelled" path without a person, so `InMemoryKeychain(presence:)` takes a closure called with the
prompt on each read of a presence item, returning `.granted`, `.cancelled` or `.failed`. The default
grants. This is an app-test seam, not a test-only symbol in this package: it is public API whose
purpose is apps' tests, as `InMemoryKeychain` itself is.

### 3.3 Keys for SwiftIdentity

- **SwiftIdentity 0.8.0** adds `SealingKey(data:)` and `Pepper(data:)`, with the same rule as the
  file loaders: exactly 32 bytes, or `KeyFileFailure.wrongSize`. They take bytes from any source;
  the owner-only check is a file's rule and doesn't apply.
- **SwiftKeychain** adds no dependency on SwiftIdentity. The DocC guide shows the composition:

  ```swift
  let item = KeychainItem(service: "com.example.household", account: "pepper")
  let pepper = try Pepper(data: KeychainKey.loadOrCreate(item, using: SystemKeychain()))
  ```

  A trait for a one-line adapter would add a dependency to save one line. Not worth it.

## 4. API Surface

```swift
public struct KeychainItem {
    // existing: service, account, accessibility, synchronizable, accessGroup
    public var requiresUserPresence: Bool          // default false
    public var presencePrompt: String?             // required when requiresUserPresence
}

public enum KeychainError {
    // existing: locked, missingEntitlement, malformed(String), status(Int32)
    case cancelled
    case authenticationFailed
}

public final class InMemoryKeychain {
    public enum Presence: Sendable { case granted, cancelled, failed }
    public init(presence: @escaping @Sendable (String) -> Presence = { _ in .granted })
}

// SwiftIdentity 0.8.0
extension SealingKey { public init(data: Data) throws }
extension Pepper     { public init(data: Data) throws }
```

## 6. Constraints & Compliance

- No suppressions. `LocalAuthentication` is Apple's, so it is within "Apple and swift-crypto are fine".
- Never log a prompt's answer beyond the status, and never log data.
- `Pepper(data:)` keeps the fingerprint rule: the identifier is SHA-256 of the key, first 8 bytes.

## 7. Source & API Compatibility

- SwiftKeychain 0.2.0 is source-breaking only for exhaustive `switch`es over `KeychainError`. The
  three apps that moved onto 0.1.1 on 2026-10-28 are checked and updated in the same change if they
  switch exhaustively.
- `KeychainItem`'s memberwise-style `init` gains two defaulted parameters at the end, so existing
  calls compile.
- SwiftIdentity 0.8.0 is additive.

## 10. Test Strategy

- **Validation:** a synchronizable presence item and a promptless one are refused, by both stores;
  the login keychain refuses any presence item.
- **InMemoryKeychain:** a presence item's read calls the closure with the prompt, and maps `.cancelled`
  and `.failed` to the errors; a non-presence item never calls it.
- **SystemKeychain query construction:** the attributes it sends for a presence item carry
  `kSecAttrAccessControl` and no `kSecAttrAccessible`, and reads carry an authentication context.
  Tested through the internal function `SystemKeychain` itself uses to build queries, so nothing
  exists only for tests.
- **What can't be automated:** a real prompt. The test runner is unsigned, and the data-protection
  keychain refuses an unsigned process's stores (found in 0.1.0). A manual check in a signed app
  (SwiftPushInbox is signed and on 0.1.1) is recorded in the summary, or recorded as not done.
- **SwiftIdentity:** `SealingKey(data:)`/`Pepper(data:)` accept 32 bytes and refuse others; a key
  loaded from bytes seals and opens like one loaded from a file with the same bytes; the pepper's
  identifier is the same either way.

## 12. Adversarial Review

- *"Presence makes the item safe from malware."* It doesn't: the prompt names the app, and a person
  who approves a prompt they didn't expect has approved it. It stops silent reads, not phishing.
- *"`.cancelled` will be treated as signed out."* The DocC for both new cases says not to, as `.locked`'s
  does.
- *"A promptless prompt is harmless."* On macOS the sheet then reads as a bare "wants to use your
  confidential information"; refusing it at validation costs callers one string.
- *"Keychain is 'hardware-protected' per NIST."* Not claimed. Encrypted at rest under Secure
  Enclave–guarded keys; in use, it's in memory. The Pepper DocC keeps saying a file isn't
  hardware-protected and adds what the Keychain does and doesn't change.

## 13. Alternatives Considered

- **An `AccessControl` enum** (`.none`, `.userPresence`, `.biometryCurrentSet`, …): more of Apple's
  surface than anything here needs. Biometry-only locks the person out when they re-enroll a finger,
  which is the wrong default for a credential. A `Bool` now; an enum is additive later if a case
  arrives.
- **Prompt as a parameter on `data(for:)`:** changes the protocol every conformer implements. The
  item already describes how it is protected; the prompt belongs with it.

## 14. Future Directions

- A `label` attribute, if a migration needs Keychain Access to show a name (reported by the
  FleetWatch migration if so).
- Reusing one `LAContext` across reads, so a burst of reads prompts once.

## 16. Open Questions

None blocking. Defaults chosen: `Bool` not an enum (§13); the prompt is required (§3.1).

## 17. Documentation Strategy

- The guide "Choosing Where Secrets Live" gains "Asking for the person", and a "Keys for SwiftIdentity"
  example under "Keys".
- SwiftIdentity's `Pepper` and `SealingKey` DocC name the Keychain as an alternative to the file on
  Apple platforms.

## 18. Decided while building

- **Status:** shipped in 0.2.0 on 2026-10-28, as proposed.
- `store` over an existing presence item passes the prompt's context to `SecItemUpdate`, and
  `InMemoryKeychain` asks on a replace too, so the two stores agree on which calls ask.
- `accounts(service:)` passes a context with `interactionNotAllowed`, so listing never prompts.
- Status mapping moved into `SystemKeychain.error(for:)`, which `check` uses, so the new statuses
  are tested without a Keychain.
- **Not done:** a real prompt in a signed app. The test runner is unsigned and can't store in the
  data-protection keychain; no signed app uses a presence item yet. The first one to should
  confirm the prompt shows its reason, and that cancelling arrives as `.cancelled`.
