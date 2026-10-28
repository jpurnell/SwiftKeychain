# 2026-10-28 — SwiftKeychain 0.2.0: user presence

- **Shipped:** `requiresUserPresence` and `presencePrompt` on `KeychainItem`; access control on
  add, an `LAContext` with the prompt on read and replace, a silent context on listing;
  `cancelled` and `authenticationFailed`; `InMemoryKeychain(presence:)`. The login keychain
  refuses presence items. Guide section "Asking for the person"; the Keys section shows
  SwiftIdentity 0.8.0's `Pepper(data:)` (released today alongside).
- **Tests:** `UserPresenceTests` (red first, 8 compile errors): validation, the in-memory prompt,
  the login keychain's refusal, the attributes and read query `SystemKeychain` builds, status
  mapping. 45 with both traits, 27 without.
- **Not verified:** a real prompt; needs a signed app (proposal §18).
- **Consumers:** SwiftPushInbox's PR logs errors with `String(describing:)`, so the two new cases
  need nothing there; SwiftMCPClient and FleetWatch checked when their PRs land.
