# ``SwiftKeychain``

Tokens and keys in the Apple Keychain.

## Overview

``SystemKeychain`` keeps generic-password items in the Keychain; ``InMemoryKeychain`` keeps them in
memory under the same rules, for tests. Both conform to ``KeychainAccess``, so code written
against the protocol runs on either.

Items stay on the device by default and are readable after the first unlock. A locked device
throws ``KeychainError/locked`` rather than reading as "nothing stored", so an app can't answer
it with a fresh sign-in that overwrites a good credential.

An unsigned command-line tool can't use the data-protection keychain; it passes
`dataProtection: false` to ``SystemKeychain/init(dataProtection:)`` and uses the login keychain.

## Topics

### Storing secrets

- ``KeychainAccess``
- ``KeychainItem``
- ``KeychainError``

### Stores

- ``SystemKeychain``
- ``InMemoryKeychain``

### Keys

- ``KeychainKey``
