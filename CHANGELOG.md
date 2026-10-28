# Changelog

All notable changes to SwiftKeychain will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-10-28

### Fixed

- `KeychainKey.loadOrCreate` could lose a key. Two processes that both found no key both
  stored one, and the second store replaced the first; the first process then held a key that
  was no longer stored, and whatever it had sealed with it became unreadable. A new key is now
  only added, never stored over another, and the process that loses the race returns the
  winner's key. Found while moving SwiftPushInbox's `KeychainHistoryKey`, which already did this,
  onto the package.

### Added

- `KeychainAccess.add(_:as:)`: stores only if nothing is there and says whether it did.
  `SystemKeychain` (one `SecItemAdd`) and `InMemoryKeychain` implement it atomically. A default
  implementation reads and then stores, so a conformer written for 0.1.0 still compiles; it is
  not atomic, and the documentation says so.

## [0.1.0] - 2026-10-27

The first release. Closes Stack Map gap #7, "Keychain credential store".

### Added

- `KeychainAccess`, `KeychainItem` and `KeychainError`; `SystemKeychain` (the data-protection or
  login keychain) and `InMemoryKeychain`, held to one contract by the same tests (design:
  `project/plans/proposals/2026-10-27_SwiftKeychain.md`).
- `KeychainKey.loadOrCreate`: a 32-byte key, created and stored if missing; a stored item of
  the wrong size is refused rather than replaced.
- `KeychainTokenCache` (trait `CLIAuth`): swift-cli-kit-auth's `TokenCache` as one device-only
  item, in the login keychain by default. An empty token is refused; a stored item that isn't
  text throws rather than reading as signed out.
- `KeychainClientStorage` (trait `OAuth`): swift-oauth's `OAuthClientStorage`, one device-only
  item per connection, never synchronized. The account name is the `ConnectionID` as JSON with
  sorted keys. An item that doesn't decode throws rather than reading as not connected.
- A guide, "Choosing Where Secrets Live": accessibility classes, synchronizing (and why OAuth
  credentials never do), the data-protection and login keychains, access groups, keys.
- Traits `OAuth` and `CLIAuth`, off by default, for the swift-oauth and swift-cli-kit-auth
  conformances.

[Unreleased]: https://github.com/jpurnell/SwiftKeychain/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/jpurnell/SwiftKeychain/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jpurnell/SwiftKeychain/releases/tag/v0.1.0
