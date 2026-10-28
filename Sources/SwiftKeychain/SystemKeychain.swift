// SystemKeychain.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-27.

import Foundation
import LocalAuthentication
import Security
#if canImport(os)
import os
#endif

/// The Apple Keychain, as generic-password items.
///
/// Storing adds the item, and updates it if it is already there, so a rotated token replaces
/// the old one in one call with no read in between.
///
/// On macOS, `dataProtection` chooses the keychain. The data-protection keychain, the same one
/// iOS uses, needs a signed app with a keychain entitlement; an unsigned command-line tool gets
/// ``KeychainError/missingEntitlement`` there when it stores, and should pass `false` to use the
/// login keychain, which may ask the person once to allow access. Its reads there come back
/// `nil`, because the system answers them "not found" rather than refusing.
///
/// An item that asks for the person (``KeychainItem/requiresUserPresence``) is stored under access
/// control and needs the data-protection keychain. Reading it shows the system prompt with the
/// item's ``KeychainItem/presencePrompt``; replacing it may too; adding, deleting and listing don't.
public struct SystemKeychain: KeychainAccess {

    private static let logger = Logger(subsystem: "com.swiftkeychain", category: "SystemKeychain")

    /// Whether items go to the data-protection keychain. Ignored outside macOS, where there is no other.
    public let dataProtection: Bool

    /// Creates an accessor.
    /// - Parameter dataProtection: On macOS, use the data-protection keychain (`true`, for
    ///   signed apps) or the login keychain (`false`, for command-line tools).
    public init(dataProtection: Bool = true) {
        self.dataProtection = dataProtection
    }

    /// The data stored as `item`.
    /// - Parameter item: The item to read.
    /// - Returns: The data, or `nil` if there is no such item.
    /// - Throws: ``KeychainError``.
    public func data(for item: KeychainItem) throws(KeychainError) -> Data? {
        let query = try readQuery(for: item)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try Self.check(status, doing: "read")
        guard let data = result as? Data else {
            throw .malformed("the item's data was not returned as bytes")
        }
        return data
    }

    /// Stores `data` as `item`, replacing whatever was there.
    /// - Parameters:
    ///   - data: The secret.
    ///   - item: Where it goes, and who may read it.
    /// - Throws: ``KeychainError``.
    public func store(_ data: Data, as item: KeychainItem) throws(KeychainError) {
        guard try !add(data, as: item) else { return }
        var changes = try protection(of: item)
        changes[kSecValueData as String] = data
        var query = identity(of: item)
        if item.requiresUserPresence {
            query[kSecUseAuthenticationContext as String] = Self.context(prompt: item.prompt)
        }
        try Self.check(SecItemUpdate(query as CFDictionary, changes as CFDictionary), doing: "update")
    }

    /// Stores `data` as `item` only if nothing is stored there yet: one add, which the Keychain
    /// refuses as a duplicate if another process got there first.
    /// - Parameters:
    ///   - data: The secret.
    ///   - item: Where it goes, and who may read it.
    /// - Returns: `true` if this call stored it, `false` if an item was already there.
    /// - Throws: ``KeychainError``.
    public func add(_ data: Data, as item: KeychainItem) throws(KeychainError) -> Bool {
        let status = SecItemAdd(try addAttributes(for: item, data: data) as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        try Self.check(status, doing: "add")
        return true
    }

    /// Removes `item`, if it is there.
    /// - Parameter item: The item to remove.
    /// - Throws: ``KeychainError``.
    public func delete(_ item: KeychainItem) throws(KeychainError) {
        try checkSupported(item)
        let status = SecItemDelete(identity(of: item) as CFDictionary)
        if status == errSecItemNotFound { return }
        try Self.check(status, doing: "delete")
    }

    /// The accounts stored under `service`, synchronized or not, sorted.
    /// - Parameter service: The service to list.
    /// - Returns: The account names, or none.
    /// - Throws: ``KeychainError``.
    public func accounts(service: String) throws(KeychainError) -> [String] {
        var query = base()
        query[kSecAttrService as String] = service
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        // Listing names never needs the person; an item under access control mustn't prompt for it.
        let silent = LAContext()
        silent.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = silent
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try Self.check(status, doing: "list")
        guard let found = result as? [[String: Any]] else {
            throw .malformed("the item list was not returned as attributes")
        }
        return Set(found.compactMap { $0[kSecAttrAccount as String] as? String }).sorted()
    }

    // MARK: - Queries

    /// Refuses an item this keychain can't hold as asked: the item's own rules, and, in the
    /// login keychain, any item that asks for the person, which only the data-protection
    /// keychain can honour. Storing it without that protection would be worse than refusing.
    private func checkSupported(_ item: KeychainItem) throws(KeychainError) {
        try item.validate()
        guard dataProtection || !item.requiresUserPresence else {
            throw .malformed("the login keychain can't ask for the person; use the data-protection keychain")
        }
    }

    /// What `add` sends: the item, its data, and its protection.
    func addAttributes(for item: KeychainItem, data: Data) throws(KeychainError) -> [String: Any] {
        try checkSupported(item)
        var attributes = identity(of: item)
        attributes.merge(try protection(of: item)) { _, new in new }
        attributes[kSecValueData as String] = data
        return attributes
    }

    /// What a read of `item` sends: for an item that asks for the person, with a context that
    /// carries the prompt.
    func readQuery(for item: KeychainItem) throws(KeychainError) -> [String: Any] {
        try checkSupported(item)
        var query = identity(of: item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if item.requiresUserPresence {
            query[kSecUseAuthenticationContext as String] = Self.context(prompt: item.prompt)
        }
        return query
    }

    /// The accessibility class, or, for an item that asks for the person, access control over
    /// that class. The Keychain takes one or the other, never both.
    private func protection(of item: KeychainItem) throws(KeychainError) -> [String: Any] {
        let accessible = Self.accessible(item.accessibility)
        guard item.requiresUserPresence else {
            return [kSecAttrAccessible as String: accessible]
        }
        guard let control = SecAccessControlCreateWithFlags(nil, accessible, .userPresence, nil) else {
            throw .malformed("the system could not create access control for user presence")
        }
        return [kSecAttrAccessControl as String: control]
    }

    /// A context whose prompt says what the read is for.
    private static func context(prompt: String) -> LAContext {
        let context = LAContext()
        context.localizedReason = prompt
        return context
    }

    /// The attributes every query shares.
    private func base() -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// The attributes that pick out exactly `item`.
    private func identity(of item: KeychainItem) -> [String: Any] {
        var query = base()
        query[kSecAttrService as String] = item.service
        query[kSecAttrAccount as String] = item.account
        query[kSecAttrSynchronizable as String] = item.synchronizable
        if let group = item.accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    private static func accessible(_ accessibility: KeychainItem.Accessibility) -> CFString {
        switch accessibility {
        case .whenUnlockedThisDeviceOnly: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlocked: kSecAttrAccessibleWhenUnlocked
        case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlock
        }
    }

    /// Turns a status other than success into the error that names it, and logs it.
    private static func check(_ status: OSStatus, doing operation: String) throws(KeychainError) {
        guard status != errSecSuccess else { return }
        let failure = error(for: status)
        switch failure {
        case .locked, .cancelled:
            logger.notice("keychain \(operation, privacy: .public) refused: \(String(describing: failure), privacy: .public)")
        default:
            logger.error("keychain \(operation, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
        }
        throw failure
    }

    /// The error a status other than success names.
    static func error(for status: OSStatus) -> KeychainError {
        switch status {
        case errSecInteractionNotAllowed: .locked
        case errSecMissingEntitlement: .missingEntitlement
        case errSecUserCanceled: .cancelled
        case errSecAuthFailed: .authenticationFailed
        default: .status(status)
        }
    }
}
