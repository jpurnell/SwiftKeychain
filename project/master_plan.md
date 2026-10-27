# SwiftKeychain — Master Plan

## Vision

Tokens and keys in the Apple Keychain, for apps built on swift-oauth and swift-cli-kit-auth. It
closes Stack Map gap #7 ("Keychain credential store"): those libraries take storage as a
protocol and build on Linux, so the Keychain-backed conformances live here, and an app opts in.

**Users:** app developers who sign people in with swift-oauth or swift-cli-kit-auth and need
the credentials to survive a relaunch without sitting in a file.

**Different from** the Keychain code already in SwiftMCPClient, FleetWatch and IconquerCLI: one
tested store for all of them, with the rules (device-only OAuth, a locked device isn't signed
out) written down once.

## Architecture

- Swift 6.2, strict concurrency. Foundation and Security only for the core.
- Traits, off by default: `OAuth` (swift-oauth) and `CLIAuth` (swift-cli-kit-auth). A disabled
  trait's dependency isn't downloaded.
- macOS 14, iOS 17, visionOS 1. No Linux: the Keychain isn't there, and Linux apps keep the file
  stores in swift-oauth and swift-cli-kit-auth.

```
Sources/SwiftKeychain/
├── SwiftKeychain.swift      KeychainAccess, KeychainError, KeychainItem
├── InMemoryKeychain.swift   the store apps test against
└── SystemKeychain.swift     SecItem*, data-protection or login keychain
```

| Type | Role |
|---|---|
| `KeychainAccess` | Read, store (add, then update), delete, list accounts |
| `KeychainItem` | Service, account, accessibility, synchronizable, access group |
| `KeychainError` | `locked`, `missingEntitlement`, `malformed`, `status` |
| `SystemKeychain` | The Apple Keychain |
| `InMemoryKeychain` | The same rules, in memory |

## Key Decisions

1. **Its own package, adapters behind traits** (the user, 2026-10-27; proposal §17).
2. **OAuth credentials are device-only.** A rotating refresh token synced to two devices gets the
   token family revoked on reuse (proposal §12).
3. **A locked device throws `.locked`**, never reads as "nothing stored".
4. **Command-line tools use the login keychain** (`SystemKeychain(dataProtection: false)`; the user,
   2026-10-27).
5. **Public repository, proprietary licence** (the user, 2026-10-27).

## Current Status

- [x] Design proposal: `project/plans/proposals/2026-10-27_SwiftKeychain.md` (decisions §15, §17)
- [x] Core: `KeychainAccess`, `KeychainItem`, `KeychainError`, `InMemoryKeychain`, `SystemKeychain`
- [ ] `KeychainKey.loadOrCreate` (32-byte keys, never replaced if malformed)
- [ ] `KeychainTokenCache` (`CLIAuth`)
- [ ] `KeychainClientStorage` (`OAuth`)
- [ ] Gate and CI build with traits (quality-gate-swift `feat/swiftpm-traits`)
- [ ] 0.1.0

## Roadmap

### 0.1.0
- [ ] The core, `KeychainKey`, both adapters, README and guide; gate 0/0; CI green.

### Later
- `SecAccessControl` with user presence for step-up.
- SwiftIdentity `SealingKey(data:)` and `Pepper(data:)`, so its server keys can come from here.
- Move SwiftMCPClient and FleetWatch onto this package.

---

**Last Updated:** 2026-10-27 (the core built; adapters next.)
