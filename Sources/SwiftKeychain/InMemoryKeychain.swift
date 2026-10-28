// InMemoryKeychain.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-27.

import Foundation
#if canImport(os)
import os
#endif

/// A ``KeychainAccess`` held in memory, for an app's tests.
///
/// It keeps the Keychain's rules: items are told apart by service, account, access group and
/// whether they synchronize; storing replaces; a device-only item can't synchronize. The real
/// Keychain prompts, behaves differently under an unsigned test runner, and leaves items behind
/// on the machine that ran the tests.
public final class InMemoryKeychain: KeychainAccess {

    private struct Key: Hashable {
        let service: String
        let account: String
        let accessGroup: String?
        let synchronizable: Bool

        init(_ item: KeychainItem) {
            service = item.service
            account = item.account
            accessGroup = item.accessGroup
            synchronizable = item.synchronizable
        }
    }

    private let items = OSAllocatedUnfairLock(initialState: [Key: Data]())

    /// Creates an empty store.
    public init() {}

    /// The data stored as `item`.
    /// - Parameter item: The item to read.
    /// - Returns: The data, or `nil` if there is no such item.
    /// - Throws: ``KeychainError/malformed(_:)`` for an item no store can hold.
    public func data(for item: KeychainItem) throws(KeychainError) -> Data? {
        try item.validate()
        return items.withLock { $0[Key(item)] }
    }

    /// Stores `data` as `item`, replacing whatever was there.
    /// - Parameters:
    ///   - data: The secret.
    ///   - item: Where it goes.
    /// - Throws: ``KeychainError/malformed(_:)`` for an item no store can hold.
    public func store(_ data: Data, as item: KeychainItem) throws(KeychainError) {
        try item.validate()
        items.withLock { $0[Key(item)] = data }
    }

    /// Stores `data` as `item` only if nothing is stored there yet.
    /// - Parameters:
    ///   - data: The secret.
    ///   - item: Where it goes.
    /// - Returns: `true` if this call stored it, `false` if an item was already there.
    /// - Throws: ``KeychainError/malformed(_:)`` for an item no store can hold.
    public func add(_ data: Data, as item: KeychainItem) throws(KeychainError) -> Bool {
        try item.validate()
        return items.withLock { items in
            guard items[Key(item)] == nil else { return false }
            items[Key(item)] = data
            return true
        }
    }

    /// Removes `item`, if it is there.
    /// - Parameter item: The item to remove.
    /// - Throws: ``KeychainError/malformed(_:)`` for an item no store can hold.
    public func delete(_ item: KeychainItem) throws(KeychainError) {
        try item.validate()
        _ = items.withLock { $0.removeValue(forKey: Key(item)) }
    }

    /// The accounts stored under `service`, sorted.
    /// - Parameter service: The service to list.
    /// - Returns: The account names, or none.
    public func accounts(service: String) throws(KeychainError) -> [String] {
        items.withLock { items in
            Set(items.keys.filter { $0.service == service }.map(\.account)).sorted()
        }
    }
}
