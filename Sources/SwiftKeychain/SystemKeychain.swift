// SystemKeychain.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-27.

import Foundation
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
        try item.validate()
        var query = identity(of: item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
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
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessible(item.accessibility),
        ]
        try Self.check(SecItemUpdate(identity(of: item) as CFDictionary, changes as CFDictionary), doing: "update")
    }

    /// Stores `data` as `item` only if nothing is stored there yet: one add, which the Keychain
    /// refuses as a duplicate if another process got there first.
    /// - Parameters:
    ///   - data: The secret.
    ///   - item: Where it goes, and who may read it.
    /// - Returns: `true` if this call stored it, `false` if an item was already there.
    /// - Throws: ``KeychainError``.
    public func add(_ data: Data, as item: KeychainItem) throws(KeychainError) -> Bool {
        try item.validate()
        var added = identity(of: item)
        added[kSecValueData as String] = data
        added[kSecAttrAccessible as String] = Self.accessible(item.accessibility)
        let status = SecItemAdd(added as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        try Self.check(status, doing: "add")
        return true
    }

    /// Removes `item`, if it is there.
    /// - Parameter item: The item to remove.
    /// - Throws: ``KeychainError``.
    public func delete(_ item: KeychainItem) throws(KeychainError) {
        try item.validate()
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

    /// Turns a status other than success into the error that names it.
    private static func check(_ status: OSStatus, doing operation: String) throws(KeychainError) {
        switch status {
        case errSecSuccess:
            return
        case errSecInteractionNotAllowed:
            logger.notice("keychain \(operation, privacy: .public) refused: locked")
            throw .locked
        case errSecMissingEntitlement:
            logger.error("keychain \(operation, privacy: .public) refused: missing entitlement")
            throw .missingEntitlement
        default:
            logger.error("keychain \(operation, privacy: .public) failed with status \(status, privacy: .public)")
            throw .status(status)
        }
    }
}
