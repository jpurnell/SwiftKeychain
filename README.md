# SwiftKeychain

Tokens and keys in the Apple Keychain, for apps built on
[swift-oauth](https://github.com/jpurnell/swift-oauth) and
[swift-cli-kit-auth](https://github.com/jpurnell/swift-cli-kit-auth).

**Status: in development, not yet released.** The core store is built; the swift-oauth and
swift-cli-kit-auth conformances are next.

## What it does

- **`SystemKeychain`** stores, reads, replaces, lists and deletes generic-password items.
  Storing a rotated token replaces the old one in one call.
- **`InMemoryKeychain`** keeps the same rules in memory, for your tests.
- **A locked device throws `.locked`.** It never reads as "nothing stored", so an app can't
  answer it with a fresh sign-in that overwrites a good credential.
- **Items stay on the device by default** (after first unlock, not synchronized). An item can't
  be both device-only and synchronized; that is refused, with a reason.

## Command-line tools

An unsigned command-line tool can't use the data-protection keychain. Use the login keychain:

```swift
let keychain = SystemKeychain(dataProtection: false)
```

macOS may ask once to allow access.

## Traits

The conformances for swift-oauth and swift-cli-kit-auth are behind traits, off by default, so an
app that wants only the core downloads nothing else.

## Requirements

- Swift 6.2+
- macOS 14+, iOS 17+ or visionOS 1+. Not Linux: there is no Keychain there.

## Licence

Proprietary. See [LICENSE](LICENSE).
