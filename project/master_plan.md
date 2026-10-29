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
- macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1 (tvOS and watchOS from 0.2.0, without user
  presence). No Linux: the Keychain isn't there, and Linux apps keep the file
  stores in swift-oauth and swift-cli-kit-auth.

```
Sources/SwiftKeychain/
├── SwiftKeychain.swift      KeychainAccess, KeychainError, KeychainItem
├── InMemoryKeychain.swift   the store apps test against
├── SystemKeychain.swift     SecItem*, data-protection or login keychain
├── PresenceReuse.swift      the bounded window one confirmation stands for
├── KeychainKey.swift        32-byte keys, never replaced if malformed
├── KeychainTokenCache.swift      (CLIAuth) swift-cli-kit-auth's TokenCache
└── KeychainClientStorage.swift   (OAuth) swift-oauth's OAuthClientStorage
```

| Type | Role |
|---|---|
| `KeychainAccess` | Read, store (add, then update), add only if absent, delete, list accounts |
| `KeychainItem` | Service, account, accessibility, synchronizable, access group, user presence and its prompt, label (not identity) |
| `KeychainError` | `locked`, `missingEntitlement`, `malformed`, `status`, `cancelled`, `authenticationFailed` |
| `SystemKeychain` | The Apple Keychain; opt-in `presenceReuse` (≤ 5 min) so a burst of reads asks once |
| `InMemoryKeychain` | The same rules, in memory; prompts answered by a closure; the reuse window on a clock tests move |
| `PresenceSession` (internal) | The authenticated `LAContext` a burst shares, held in a lock with its window |
| `KeychainKey` | A 32-byte key, read or created; a key another process created first wins |
| `KeychainTokenCache` | `TokenCache` (trait `CLIAuth`), login keychain by default |
| `KeychainClientStorage` | `OAuthClientStorage` (trait `OAuth`), one device-only item per connection |

## Key Decisions

1. **Its own package, adapters behind traits** (the user, 2026-10-27; proposal §17).
2. **OAuth credentials are device-only.** A rotating refresh token synced to two devices gets the
   token family revoked on reuse (proposal §12).
3. **A locked device throws `.locked`**, never reads as "nothing stored".
4. **Command-line tools use the login keychain** (`SystemKeychain(dataProtection: false)`; the user,
   2026-10-27).
5. **Public repository, proprietary licence** (the user, 2026-10-27).
6. **Presence reuse is opt-in and bounded**: off by default, at most five minutes, from the
   confirmation and not sliding, ended by any refusal (proposal `2026-10-28_OnePrompt03.md`).

## Current Status

- [x] Design proposal: `project/plans/completed/2026-10-27_SwiftKeychain.md` (decisions §15, §17)
- [x] Core: `KeychainAccess`, `KeychainItem`, `KeychainError`, `InMemoryKeychain`, `SystemKeychain`
- [x] `KeychainKey.loadOrCreate` (32-byte keys, never replaced if malformed)
- [x] `KeychainTokenCache` (`CLIAuth`; defaults to the login keychain)
- [x] `KeychainClientStorage` (`OAuth`; device-only, JSON account names; data-protection keychain by default)
- [x] Gate and CI build with traits (quality-gate-swift #63, `traits: [OAuth, CLIAuth]` in `.quality-gate.yml`)
- [x] 0.1.0 released 2026-10-27, CI on `main` green
- [x] 0.1.1: `KeychainAccess.add(_:as:)`; `KeychainKey.loadOrCreate` no longer replaces a key another process created first
- [x] 0.2.0: user presence (`SecAccessControl`, `LAContext` prompt), `cancelled` and `authenticationFailed`,
      `InMemoryKeychain(presence:)`; SwiftIdentity 0.8.0's keys from bytes documented
- [x] 0.3.0: `KeychainItem.label`; `presenceReuse` on both stores and `endPresenceReuse()`
- [ ] Consumers moved onto the package: **PRs open, not merged** — SwiftPushInbox #1, SwiftMCPClient #4,
      FleetWatch #24 (including the Reporter, now on macOS 14). Marked done when each is merged and
      checked on real data.
- [ ] A real prompt confirmed in a signed app (tests can't; the runner is unsigned): the reason shows,
      cancelling arrives as `.cancelled`, and a second read inside a `presenceReuse` window doesn't ask.

## Roadmap

### 0.1.0 (released 2026-10-27)
- [x] The core, `KeychainKey`, both adapters, README and guide; gate 0/0; CI green.

### 0.1.1 (2026-10-28)
- [x] Atomic `add`, and `KeychainKey` creation that survives two processes racing. Not on the
      plan: found while moving SwiftPushInbox onto the package.

### 0.2.0 (2026-10-28)
- [x] ~~`SecAccessControl` with user presence for step-up.~~ Shipped as a `Bool` and a required prompt, not an
      access-control enum: biometry-only would lock a person out when they re-enrol a finger (proposal §13).
- [x] ~~SwiftIdentity `SealingKey(data:)` and `Pepper(data:)`, so its server keys can come from here.~~ Shipped in
      SwiftIdentity 0.8.0; this package documents the composition rather than depending on SwiftIdentity.

### 0.3.0 (2026-10-28)
- [x] ~~A `label` attribute, if a migration shows Keychain Access needs a name.~~ The FleetWatch migration
      showed it: its items lost "FleetWatch sign-in" and "FleetWatch Reporter". Shipped as `KeychainItem.label`,
      never part of identity.
- [x] ~~One `LAContext` across a burst of reads, so it prompts once.~~ Shipped as an opt-in window on the
      store (`presenceReuse`, capped at five minutes, not sliding), not a scoped value per burst, so the
      adapters get it unchanged (proposal `2026-10-28_OnePrompt03.md` §13).

### 1.0.0-beta.1 (next)
- [ ] Gate (the user, 2026-10-28): FleetWatch on 0.3.0 (PR #24, the app and the Reporter) is
      notarized and passes its real checks: the app stays signed in, an enrolled Mac's Reporter
      keeps reporting without re-enrolling, labels show in Keychain Access. Then 1.0.0-beta.1, with
      the public API reviewed for what a 1.0 commits to.

### Later
- Move SwiftPushInbox, SwiftMCPClient and FleetWatch onto this package. Under way 2026-10-28: **PRs open,
  not merged** (SwiftPushInbox #1, SwiftMCPClient #4, FleetWatch #24 incl. the Reporter now on macOS 14).
  To be marked done when merged and checked on real data. (An earlier edit struck this through as if
  done; it wasn't.)
- Confirm a real prompt in a signed app (tests can't; runner unsigned), including that `presenceReuse`
  really suppresses the second prompt.
- ~~Split the package so the core can support older macOS.~~ Considered and declined 2026-10-28: the
  integrations' dependencies need macOS 14 and a package has one floor; Vector Sigma on 10.13 uses
  FleetWatch's legacy scripts, so nothing needs it.

---

**Last Updated:** 2026-10-28 (1.0.0-beta.1 planned, gated on FleetWatch's notarized checks. Earlier the same day, 0.3.0: label and presence reuse; type table, layout, status and roadmap reconciled; the consumer migrations un-struck and marked as open PRs, not merged; the signed-app prompt check added; the package split recorded as declined. Earlier the same day, 0.2.0: user presence; type table, status and roadmap reconciled. Earlier the same day, 0.1.1: atomic `add` and the key-creation race; type table and roadmap reconciled. Earlier, 2026-10-27, 0.1.0 released: the layout and type table reconciled with what shipped; the proposal moved to completed. Earlier the same day: the core, `KeychainKey` and both conformances built, and the gate taught traits.)
