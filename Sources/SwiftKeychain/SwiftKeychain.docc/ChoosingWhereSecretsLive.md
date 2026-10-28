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

On iOS, tvOS, watchOS and visionOS there is one keychain. On macOS ``SystemKeychain`` chooses between two:

- **The data-protection keychain** (`SystemKeychain()`), the same one iOS uses, for signed apps
  with a keychain entitlement. An unsigned process is refused when it stores, with
  ``KeychainError/missingEntitlement``; its reads come back `nil`, because the system answers
  them "not found".
- **The login keychain** (`SystemKeychain(dataProtection: false)`), for command-line tools, which
  are usually unsigned. macOS may ask the person once to allow access. `KeychainTokenCache` uses
  it by default.

## Asking for the person

Set ``KeychainItem/requiresUserPresence`` for a secret whose use should be a deliberate act, such
as a signing key or an administrator's token. Each read then shows the system prompt (Touch ID,
Face ID, Optic ID, or the device passcode or account password) with the item's
``KeychainItem/presencePrompt``, which is required: a prompt that doesn't say why is one the
person can't judge.

```swift
import SwiftKeychain

let item = KeychainItem(
    service: "com.example.signer",
    account: "release-key",
    accessibility: .whenUnlockedThisDeviceOnly,
    requiresUserPresence: true,
    presencePrompt: "Sign the release"
)
print(item.requiresUserPresence)
```

Reading may now throw two more errors. ``KeychainError/cancelled`` means the person dismissed
the prompt; ``KeychainError/authenticationFailed`` means they tried and couldn't. Neither means
the item is gone, so neither should be answered with a new sign-in, and a dismissed prompt
shouldn't reappear at once.

Which calls ask: reading does; replacing an existing item may; adding, deleting and listing
accounts don't. Such items need the data-protection keychain, so on macOS
`SystemKeychain(dataProtection: false)` refuses them rather than storing them without the
protection asked for. tvOS and watchOS can't show the prompt, so they refuse them too. They
don't synchronize.

It stops silent reads, not persuasion: a person who approves a prompt they didn't expect has
approved it. To test what an app does when the person says no, give ``InMemoryKeychain`` a
`presence` closure that answers ``InMemoryKeychain/Presence/cancelled``.

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

SwiftIdentity's server keys take its bytes as they are (SwiftIdentity 0.8.0 or later), so a
pepper or a one-time-code sealing key can live here instead of in an owner-only file:

```
let item = KeychainItem(service: "com.example.household", account: "pepper")
let pepper = try Pepper(data: KeychainKey.loadOrCreate(item, using: SystemKeychain()))
```

That keeps the key encrypted at rest under keys the Secure Enclave guards, and out of backups
while the item is device-only. It is still in memory while it's used, so it isn't the
"hardware-protected area" NIST SP 800-63B-4 §3.1.1.2 asks for either.
