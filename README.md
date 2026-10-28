# SwiftKeychain

Tokens and keys in the Apple Keychain, for apps built on
[swift-oauth](https://github.com/jpurnell/swift-oauth) and
[swift-cli-kit-auth](https://github.com/jpurnell/swift-cli-kit-auth).

**Status: 0.2.0.** The core store, `KeychainKey`, items that ask for the person (Touch ID, Face ID
or a password) before they are read, and the swift-oauth and swift-cli-kit-auth conformances.

```swift
dependencies: [
    .package(url: "https://github.com/jpurnell/SwiftKeychain.git", from: "0.1.0"),
]
```

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

The conformances are behind traits, off by default, so an app that wants only the core downloads
nothing else:

```swift
.package(url: "https://github.com/jpurnell/SwiftKeychain.git", from: "0.1.0", traits: ["OAuth"])
```

- **`OAuth`**: `KeychainClientStorage`, swift-oauth's `OAuthClientStorage`. One item per
  connection, kept on the device and never synchronized: a rotating refresh token on two devices
  gets the whole token family revoked.
- **`CLIAuth`**: `KeychainTokenCache`, swift-cli-kit-auth's `TokenCache`, in the login keychain by
  default.

`KeychainKey.loadOrCreate` gives a 32-byte key for swift-oauth's `EncryptedFileClientStorage`,
if you'd rather keep credentials in a file sealed by a Keychain key.

## Documentation

The DocC catalogue includes **Choosing Where Secrets Live**: accessibility classes, synchronizing,
which keychain, access groups and keys.

## Requirements

- Swift 6.2+
- macOS 14+, iOS 17+, tvOS 17+, watchOS 10+ or visionOS 1+. Items that ask for the person need
  macOS, iOS or visionOS. Not Linux: there is no Keychain there.

## Licence

Proprietary. See [LICENSE](LICENSE).
