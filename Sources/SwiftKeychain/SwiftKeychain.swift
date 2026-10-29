// SwiftKeychain.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-27.

import Foundation

/// Somewhere small secrets are kept: the system Keychain, or an in-memory stand-in for tests.
///
/// Every call is synchronous, as the Keychain's are. An item that isn't there reads as `nil`;
/// anything else that stops a read, such as a locked device, throws, so it can't be mistaken for
/// "nothing stored" and answered with a fresh sign-in that overwrites a good credential.
public protocol KeychainAccess: Sendable {

    /// The data stored as `item`.
    /// - Parameter item: The item to read.
    /// - Returns: The data, or `nil` if there is no such item.
    /// - Throws: ``KeychainError``.
    func data(for item: KeychainItem) throws(KeychainError) -> Data?

    /// Stores `data` as `item`, replacing whatever was there.
    /// - Parameters:
    ///   - data: The secret.
    ///   - item: Where it goes, and who may read it.
    /// - Throws: ``KeychainError``.
    func store(_ data: Data, as item: KeychainItem) throws(KeychainError)

    /// Stores `data` as `item` only if nothing is stored there yet, leaving what is.
    ///
    /// For a value two processes may both create, such as a key: the one that loses the race
    /// reads the winner's instead of replacing it.
    /// - Parameters:
    ///   - data: The secret.
    ///   - item: Where it goes, and who may read it.
    /// - Returns: `true` if this call stored it, `false` if an item was already there.
    /// - Throws: ``KeychainError``.
    func add(_ data: Data, as item: KeychainItem) throws(KeychainError) -> Bool

    /// Removes `item`. Removing an item that isn't there is not an error.
    /// - Parameter item: The item to remove.
    /// - Throws: ``KeychainError``.
    func delete(_ item: KeychainItem) throws(KeychainError)

    /// The accounts stored under `service`, sorted. Reads names only, never data.
    /// - Parameter service: The service to list.
    /// - Returns: The account names, or none.
    /// - Throws: ``KeychainError``.
    func accounts(service: String) throws(KeychainError) -> [String]
}

extension KeychainAccess {

    /// Reads, then stores only if nothing was there.
    ///
    /// For a store written before ``KeychainAccess/add(_:as:)`` was part of the protocol. It is
    /// not atomic: a write between the read and the store is replaced. ``SystemKeychain`` and
    /// ``InMemoryKeychain`` implement `add` atomically, and a store that can should too.
    /// - Parameters:
    ///   - data: The secret.
    ///   - item: Where it goes, and who may read it.
    /// - Returns: `true` if this call stored it, `false` if an item was already there.
    /// - Throws: ``KeychainError``.
    public func add(_ data: Data, as item: KeychainItem) throws(KeychainError) -> Bool {
        guard try self.data(for: item) == nil else { return false }
        try store(data, as: item)
        return true
    }
}

/// Why the Keychain refused.
///
/// Carries statuses and reasons, never the secret: an error ends up in logs.
public enum KeychainError: Error, Equatable, Sendable {

    /// The device is locked, or the item can't be read until it is unlocked
    /// (`errSecInteractionNotAllowed`). Not "signed out": the item may well be there.
    case locked

    /// The process lacks the entitlement the item needs (`errSecMissingEntitlement`), as an
    /// unsigned command-line tool does for the data-protection keychain.
    case missingEntitlement

    /// The item, or what it holds, isn't what the caller asked for.
    case malformed(String)

    /// Any other Keychain status, carried as it came.
    case status(Int32)

    /// The person dismissed the prompt for an item that asks for them (`errSecUserCanceled`).
    /// Not "signed out", and not a reason to ask again at once.
    case cancelled

    /// The person tried to confirm it was them, and couldn't (`errSecAuthFailed`).
    case authenticationFailed
}

/// One item in the Keychain: where it is filed, and who may read it.
public struct KeychainItem: Sendable, Hashable {

    /// When an item can be read.
    public enum Accessibility: Sendable, Hashable {
        /// While the device is unlocked, on this device only.
        case whenUnlockedThisDeviceOnly
        /// After the first unlock since boot, on this device only. The default.
        case afterFirstUnlockThisDeviceOnly
        /// While the device is unlocked; may be synchronized.
        case whenUnlocked
        /// After the first unlock since boot; may be synchronized.
        case afterFirstUnlock

        /// Whether the class keeps the item on this device.
        public var isDeviceOnly: Bool {
            switch self {
            case .whenUnlockedThisDeviceOnly, .afterFirstUnlockThisDeviceOnly: true
            case .whenUnlocked, .afterFirstUnlock: false
            }
        }
    }

    /// The service the item is filed under, such as the app's bundle identifier.
    public var service: String
    /// The account within the service.
    public var account: String
    /// When it can be read. Defaults to after first unlock, on this device only.
    public var accessibility: Accessibility
    /// Whether iCloud Keychain synchronizes it to the person's other devices. Defaults to `false`.
    public var synchronizable: Bool
    /// The access group shared between apps, or `nil` for the app's own.
    public var accessGroup: String?
    /// Whether each read asks for the person: Touch ID, Face ID, Optic ID, or the device passcode
    /// or account password. Defaults to `false`. Needs the data-protection keychain, a
    /// ``presencePrompt``, and an item that doesn't synchronize.
    public var requiresUserPresence: Bool
    /// What the prompt tells the person the read is for, such as "Unlock the signing key".
    public var presencePrompt: String?
    /// The name Keychain Access shows, such as "FleetWatch sign-in". Defaults to `nil`, which shows
    /// the service. It describes the item and never picks it out: an item stored without a label is
    /// found by one that has one, and storing with a new label renames the item. `nil` leaves any
    /// label already stored.
    public var label: String?

    /// Creates an item description.
    /// - Parameters:
    ///   - service: The service the item is filed under.
    ///   - account: The account within the service.
    ///   - accessibility: When it can be read.
    ///   - synchronizable: Whether it synchronizes to other devices.
    ///   - accessGroup: The shared access group, if any.
    ///   - requiresUserPresence: Whether each read asks for the person.
    ///   - presencePrompt: What the prompt says the read is for; required with `requiresUserPresence`.
    ///   - label: The name Keychain Access shows, if any; not part of the item's identity.
    public init(
        service: String,
        account: String,
        accessibility: Accessibility = .afterFirstUnlockThisDeviceOnly,
        synchronizable: Bool = false,
        accessGroup: String? = nil,
        requiresUserPresence: Bool = false,
        presencePrompt: String? = nil,
        label: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessibility = accessibility
        self.synchronizable = synchronizable
        self.accessGroup = accessGroup
        self.requiresUserPresence = requiresUserPresence
        self.presencePrompt = presencePrompt
        self.label = label
    }

    /// Refuses a combination no store can honour, saying why where the Keychain would answer
    /// with an opaque status: an item kept on this device that also synchronizes; an item that
    /// asks for the person and synchronizes, since items under access control don't; and one
    /// that asks for the person without saying why.
    /// - Throws: ``KeychainError/malformed(_:)``.
    func validate() throws(KeychainError) {
        guard !(synchronizable && accessibility.isDeviceOnly) else {
            throw .malformed("an item kept on this device can't also synchronize")
        }
        guard requiresUserPresence else { return }
        guard !synchronizable else {
            throw .malformed("an item that asks for the person can't synchronize")
        }
        let prompt = presencePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else {
            throw .malformed("an item that asks for the person needs a prompt saying why")
        }
    }

    /// The prompt, for an item ``validate()`` has passed that asks for the person.
    var prompt: String { presencePrompt ?? "" }
}
