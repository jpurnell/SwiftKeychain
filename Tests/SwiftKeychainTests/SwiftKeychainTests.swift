// SwiftKeychainTests.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-27.

import Foundation
import Testing
import SwiftKeychain

/// One contract, run against every `KeychainAccess`: the in-memory store apps test with, and the
/// system Keychain it stands in for. A fake that passed tests the real store fails is worse than
/// no fake.
@Suite("KeychainAccess contract")
struct KeychainContractTests {

    /// The stores under test. The system one uses the login keychain, which an unsigned test
    /// runner can use; each test files its items under a service of its own and removes them.
    static let stores: [any KeychainAccess & Sendable] = [InMemoryKeychain(), SystemKeychain(dataProtection: false)]

    private static func item(_ account: String = "ada") -> KeychainItem {
        KeychainItem(service: "com.swiftkeychain.tests.\(UUID().uuidString)", account: account)
    }

    @Test("A stored item reads back", arguments: stores)
    func roundTrip(_ keychain: any KeychainAccess) throws {
        let item = Self.item()
        defer { try? keychain.delete(item) }
        try keychain.store(Data("secret".utf8), as: item)
        #expect(try keychain.data(for: item) == Data("secret".utf8))
    }

    @Test("An item never stored reads as nil", arguments: stores)
    func absent(_ keychain: any KeychainAccess) throws {
        #expect(try keychain.data(for: Self.item()) == nil)
    }

    @Test("Storing again replaces, and the item keeps one value", arguments: stores)
    func replace(_ keychain: any KeychainAccess) throws {
        let item = Self.item()
        defer { try? keychain.delete(item) }
        try keychain.store(Data("first".utf8), as: item)
        try keychain.store(Data("second".utf8), as: item)
        #expect(try keychain.data(for: item) == Data("second".utf8))
        #expect(try keychain.accounts(service: item.service) == ["ada"])
    }

    @Test("Adding stores an item that isn't there, and leaves one that is", arguments: stores)
    func add(_ keychain: any KeychainAccess) throws {
        let item = Self.item()
        defer { try? keychain.delete(item) }
        #expect(try keychain.add(Data("first".utf8), as: item))
        #expect(try keychain.add(Data("second".utf8), as: item) == false)
        #expect(try keychain.data(for: item) == Data("first".utf8))
    }

    @Test("Deleting removes the item, and deleting what isn't there is not an error", arguments: stores)
    func delete(_ keychain: any KeychainAccess) throws {
        let item = Self.item()
        try keychain.store(Data("secret".utf8), as: item)
        try keychain.delete(item)
        #expect(try keychain.data(for: item) == nil)
        try keychain.delete(item)
    }

    @Test("Accounts lists a service's items, sorted, and no other service's", arguments: stores)
    func accounts(_ keychain: any KeychainAccess) throws {
        let ada = Self.item("ada")
        let grace = KeychainItem(service: ada.service, account: "grace/with a slash")
        let elsewhere = Self.item("ada")
        defer { [ada, grace, elsewhere].forEach { try? keychain.delete($0) } }
        try keychain.store(Data("a".utf8), as: grace)
        try keychain.store(Data("b".utf8), as: ada)
        try keychain.store(Data("c".utf8), as: elsewhere)

        #expect(try keychain.accounts(service: ada.service) == ["ada", "grace/with a slash"])
        #expect(try keychain.accounts(service: "com.swiftkeychain.tests.none.\(UUID().uuidString)") == [])
    }

    @Test("A synchronizable item that is also device-only is refused before it reaches the store", arguments: stores)
    func syncedDeviceOnly(_ keychain: any KeychainAccess) throws {
        var item = Self.item()
        item.synchronizable = true
        item.accessibility = .afterFirstUnlockThisDeviceOnly
        #expect(throws: KeychainError.self) { try keychain.store(Data("secret".utf8), as: item) }
        #expect(throws: KeychainError.self) { try keychain.data(for: item) }
    }

    @Test("A new item defaults to device-only, readable after first unlock, not synchronized")
    func defaults() {
        let item = KeychainItem(service: "s", account: "a")
        #expect(item.accessibility == .afterFirstUnlockThisDeviceOnly)
        #expect(!item.synchronizable)
        #expect(item.accessGroup == nil)
    }
}

@Suite("SystemKeychain")
struct SystemKeychainTests {

    /// An unsigned test runner has no keychain entitlement, so the data-protection keychain
    /// refuses to store for it, and the refusal must arrive named, not as a bare status. A read
    /// is answered "not found" by the system rather than refused, so it is `nil`: a tool
    /// misconfigured this way sees nothing stored, and its first save fails loudly.
    @Test("The data-protection keychain refuses an unsigned process's store as missingEntitlement")
    func dataProtectionUnsigned() throws {
        let keychain = SystemKeychain()
        let item = KeychainItem(service: "com.swiftkeychain.tests.\(UUID().uuidString)", account: "ada")
        defer { try? keychain.delete(item) }
        #expect(throws: KeychainError.missingEntitlement) { try keychain.store(Data("secret".utf8), as: item) }
        #expect(try keychain.data(for: item) == nil)
    }
}
