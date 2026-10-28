# Changelog

All notable changes to SwiftKeychain will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- Traits `OAuth` and `CLIAuth`, off by default, for the swift-oauth and swift-cli-kit-auth
  conformances.
