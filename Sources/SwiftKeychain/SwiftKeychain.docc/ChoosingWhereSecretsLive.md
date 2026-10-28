# Choosing Where Secrets Live

Pick when an item can be read, whether it leaves the device, and which keychain holds it.

## Overview

Every ``KeychainItem`` answers three questions: when can it be read, may it synchronize to the
person's other devices, and which apps share it. The defaults (readable after the first unlock,
kept on this device, the app's own) suit most tokens. This article is for when they don't.

## When an item can be read

``KeychainItem/Accessibility`` has four classes:

| Class | Readable | Leaves the device |
|---|---|---|
| ``KeychainItem/Accessibility/afterFirstUnlockThisDeviceOnly`` (default) | after the first unlock since boot | no |
| ``KeychainItem/Accessibility/whenUnlockedThisDeviceOnly`` | only while unlocked | no |
| ``KeychainItem/Accessibility/afterFirstUnlock`` | after the first unlock since boot | may synchronize |
| ``KeychainItem/Accessibility/whenUnlocked`` | only while unlocked | may synchronize |

Choose "after first unlock" for anything a background task needs, such as a token refreshed
before it lapses. Choose "when unlocked" for a secret only the person's own actions use. The
classes that are readable even before the first unlock aren't offered: the quality gate's
`security.insecure-keychain` rule refuses them, and nothing here needs them.

A read the class doesn't allow yet throws ``KeychainError/locked``. Treat it as "try again
later", never as "signed out": answering it with a fresh sign-in would overwrite a credential
that is still good.

## Whether it synchronizes

Set ``KeychainItem/synchronizable`` to `true` to let iCloud Keychain copy an item to the person's
other devices. It needs a class that may leave the device; an item that is both device-only and
synchronizable is refused with ``KeychainError/malformed(_:)``, since the Keychain would reject it
with an opaque status.

Synchronize keys and long-lived secrets that mean the same thing on every device. **Don't
synchronize OAuth credentials.** A rotating refresh token copied to a second device is presented
twice; the provider sees the reuse and revokes the whole token family, signing the person out
everywhere. `KeychainClientStorage` therefore keeps every connection on the device and offers no
way to change that.

## Which keychain

On iOS and visionOS there is one keychain. On macOS ``SystemKeychain`` chooses between two:

- **The data-protection keychain** (`SystemKeychain()`), the same one iOS uses, for signed apps
  with a keychain entitlement. An unsigned process is refused when it stores, with
  ``KeychainError/missingEntitlement``; its reads come back `nil`, because the system answers
  them "not found".
- **The login keychain** (`SystemKeychain(dataProtection: false)`), for command-line tools, which
  are usually unsigned. macOS may ask the person once to allow access. `KeychainTokenCache` uses
  it by default.

## Sharing between apps

Set ``KeychainItem/accessGroup`` to a keychain access group the apps share through their
entitlements. Leave it `nil` for the app's own items.

## Keys

``KeychainKey/loadOrCreate(_:using:)`` keeps a 32-byte key: it reads the key if it is there and
creates and stores one if not. A stored item of the wrong size is refused rather than replaced,
since a new key would make everything sealed with the old one unreadable. A new key is added,
never stored over another, so when two processes start at once and both create one, the second
gets the first's key. Use it to seal a file
of credentials, such as swift-oauth's `EncryptedFileClientStorage`, when one item per credential
doesn't suit.
