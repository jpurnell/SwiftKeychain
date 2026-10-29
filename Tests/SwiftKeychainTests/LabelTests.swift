// LabelTests.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-28.

import Foundation
import Security
import Testing
@testable import SwiftKeychain

/// The name Keychain Access shows. It describes an item but never picks it out: an item stored
/// without one is found by an item that has one, and a new label renames rather than duplicates.
@Suite("Label")
struct LabelTests {

    static let stores: [any KeychainAccess & Sendable] = [InMemoryKeychain(), SystemKeychain(dataProtection: false)]

    private static func item(label: String? = nil) -> KeychainItem {
        KeychainItem(service: "com.swiftkeychain.tests.\(UUID().uuidString)", account: "ada", label: label)
    }

    /// The label the login keychain holds for `item`, read from its attributes.
    private static func storedLabel(of item: KeychainItem) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        try #require(status == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        return attributes[kSecAttrLabel as String] as? String
    }

    @Test("A new item has no label")
    func defaults() {
        #expect(KeychainItem(service: "s", account: "a").label == nil)
    }

    @Test("Adding sends the label as kSecAttrLabel, and nothing when there is none")
    func addAttributes() throws {
        let labelled = try SystemKeychain().addAttributes(for: Self.item(label: "FleetWatch sign-in"), data: Data())
        #expect(labelled[kSecAttrLabel as String] as? String == "FleetWatch sign-in")

        let plain = try SystemKeychain().addAttributes(for: Self.item(), data: Data())
        #expect(plain[kSecAttrLabel as String] == nil)
    }

    @Test("A read never asks for the label, so it doesn't decide which item is found")
    func notInIdentity() throws {
        let query = try SystemKeychain().readQuery(for: Self.item(label: "FleetWatch sign-in"))
        #expect(query[kSecAttrLabel as String] == nil)
    }

    @Test("An item stored with a label is found by one without, and a new label leaves one item", arguments: stores)
    func identity(_ keychain: any KeychainAccess) throws {
        let labelled = Self.item(label: "FleetWatch sign-in")
        var unlabelled = labelled
        unlabelled.label = nil
        var renamed = labelled
        renamed.label = "FleetWatch Reporter"
        defer { try? keychain.delete(unlabelled) }

        try keychain.store(Data("first".utf8), as: labelled)
        #expect(try keychain.data(for: unlabelled) == Data("first".utf8))
        try keychain.store(Data("second".utf8), as: renamed)
        #expect(try keychain.data(for: labelled) == Data("second".utf8))
        #expect(try keychain.accounts(service: labelled.service) == ["ada"])
    }

    @Test("The login keychain holds the label, and storing again with another renames the item")
    func storedInKeychain() throws {
        let keychain = SystemKeychain(dataProtection: false)
        var item = Self.item(label: "FleetWatch sign-in")
        defer { try? keychain.delete(item) }

        try keychain.store(Data("first".utf8), as: item)
        #expect(try Self.storedLabel(of: item) == "FleetWatch sign-in")
        item.label = "FleetWatch Reporter"
        try keychain.store(Data("second".utf8), as: item)
        #expect(try Self.storedLabel(of: item) == "FleetWatch Reporter")
    }

    @Test("A store without a label leaves the one already there")
    func nilLeavesLabel() throws {
        let keychain = SystemKeychain(dataProtection: false)
        var item = Self.item(label: "FleetWatch sign-in")
        defer { try? keychain.delete(item) }

        try keychain.store(Data("first".utf8), as: item)
        item.label = nil
        try keychain.store(Data("second".utf8), as: item)
        #expect(try Self.storedLabel(of: item) == "FleetWatch sign-in")
    }
}
