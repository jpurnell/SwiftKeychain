// KeychainClientStorageTests.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-27.

#if OAuth
import Foundation
import Testing
import SwiftOAuthClient
import SwiftKeychain

/// `KeychainClientStorage`: swift-oauth's `OAuthClientStorage`, one Keychain item per connection.
@Suite("KeychainClientStorage")
struct KeychainClientStorageTests {

    private let keychain = InMemoryKeychain()
    private var storage: KeychainClientStorage {
        KeychainClientStorage(service: "com.example.app.oauth", keychain: keychain)
    }

    private static let quickbooks = ConnectionID(tenant: "acme", provider: "quickbooks", account: "9130")
    private static let xero = ConnectionID(tenant: "acme", provider: "xero")

    private static func credential(_ refresh: String, previous: String? = nil) -> StoredCredential {
        StoredCredential(
            accessToken: "access-\(refresh)", refreshToken: refresh,
            accessExpiry: Date(timeIntervalSince1970: 2_000_000_000),
            refreshExpiry: Date(timeIntervalSince1970: 2_100_000_000),
            previousRefreshToken: previous,
            rotatedAt: Date(timeIntervalSince1970: 1_900_000_000), scope: "accounting")
    }

    @Test("A connection with nothing stored has no credential")
    func absent() async throws {
        #expect(try await storage.credential(for: Self.quickbooks) == nil)
    }

    @Test("A stored credential reads back whole, every field")
    func roundTrip() async throws {
        try await storage.store(Self.credential("r1"), for: Self.quickbooks)
        #expect(try await storage.credential(for: Self.quickbooks) == Self.credential("r1"))
    }

    @Test("A rotation replaces the credential, and the connection is listed once")
    func rotation() async throws {
        try await storage.store(Self.credential("r1"), for: Self.quickbooks)
        try await storage.store(Self.credential("r2", previous: "r1"), for: Self.quickbooks)
        #expect(try await storage.credential(for: Self.quickbooks) == Self.credential("r2", previous: "r1"))
        #expect(try await storage.connections() == [Self.quickbooks])
    }

    /// The account name is the connection as JSON, so a slash inside a field can't be mistaken
    /// for the separator that `ConnectionID.description` uses.
    @Test("Connections lists every connection, including one with a slash in a field")
    func connections() async throws {
        let slashed = ConnectionID(tenant: "acme/emea", provider: "quickbooks", account: "1")
        try await storage.store(Self.credential("a"), for: Self.quickbooks)
        try await storage.store(Self.credential("b"), for: Self.xero)
        try await storage.store(Self.credential("c"), for: slashed)
        #expect(Set(try await storage.connections()) == [Self.quickbooks, Self.xero, slashed])
        #expect(try await storage.credential(for: slashed) == Self.credential("c"))
    }

    @Test("Removing forgets one connection and leaves the others")
    func remove() async throws {
        try await storage.store(Self.credential("a"), for: Self.quickbooks)
        try await storage.store(Self.credential("b"), for: Self.xero)
        try await storage.remove(Self.quickbooks)
        #expect(try await storage.credential(for: Self.quickbooks) == nil)
        #expect(try await storage.connections() == [Self.xero])
        try await storage.remove(Self.quickbooks)
    }

    /// A synced rotating refresh token gets the token family revoked when two devices both
    /// refresh, so these items never synchronize and stay on the device.
    @Test("Credentials are device-only items, never synchronized")
    func deviceOnly() async throws {
        try await storage.store(Self.credential("a"), for: Self.quickbooks)
        let account = try #require(try keychain.accounts(service: "com.example.app.oauth").first)
        let item = KeychainItem(service: "com.example.app.oauth", account: account)
        #expect(item.accessibility.isDeviceOnly)
        #expect(!item.synchronizable)
        let stored = try #require(try keychain.data(for: item))
        #expect(try JSONDecoder().decode(StoredCredential.self, from: stored) == Self.credential("a"))
    }

    @Test("A stored item that doesn't decode is refused, not read as disconnected")
    func undecodable() async throws {
        try await storage.store(Self.credential("a"), for: Self.quickbooks)
        let account = try #require(try keychain.accounts(service: "com.example.app.oauth").first)
        try keychain.store(Data("not json".utf8), as: KeychainItem(service: "com.example.app.oauth", account: account))
        await #expect(throws: KeychainError.self) { try await storage.credential(for: Self.quickbooks) }
    }

    @Test("An account under the service that isn't a connection is refused when listing")
    func foreignAccount() async throws {
        try keychain.store(Data("x".utf8), as: KeychainItem(service: "com.example.app.oauth", account: "stray"))
        await #expect(throws: KeychainError.self) { try await storage.connections() }
    }

    @Test("JSON account names round-trip and list through the real Keychain")
    func systemKeychain() async throws {
        let storage = KeychainClientStorage(service: "com.swiftkeychain.tests.\(UUID().uuidString)",
                                            keychain: SystemKeychain(dataProtection: false))
        let slashed = ConnectionID(tenant: "acme/emea", provider: "quickbooks", account: "1")
        defer { Task { try? await storage.remove(slashed) } }
        try await storage.store(Self.credential("a"), for: slashed)
        try await storage.store(Self.credential("b", previous: "a"), for: slashed)
        #expect(try await storage.credential(for: slashed) == Self.credential("b", previous: "a"))
        #expect(try await storage.connections() == [slashed])
        try await storage.remove(slashed)
        #expect(try await storage.connections() == [])
    }

    @Test("By default the storage uses the data-protection keychain, for signed apps")
    func defaultKeychain() {
        let storage = KeychainClientStorage(service: "com.example.app.oauth")
        #expect((storage.keychain as? SystemKeychain)?.dataProtection == true)
    }
}
#endif
