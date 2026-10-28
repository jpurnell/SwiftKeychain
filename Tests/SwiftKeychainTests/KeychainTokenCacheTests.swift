// KeychainTokenCacheTests.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-27.

#if CLIAuth
import Foundation
import Testing
import SwiftCLIKitAuth
import SwiftKeychain

/// `KeychainTokenCache`: swift-cli-kit-auth's `TokenCache`, kept as one Keychain item.
@Suite("KeychainTokenCache")
struct KeychainTokenCacheTests {

    private let keychain = InMemoryKeychain()
    private var cache: KeychainTokenCache {
        KeychainTokenCache(service: "com.example.mytool", account: "token", keychain: keychain)
    }

    @Test("By default a cache uses the login keychain, which an unsigned tool can use")
    func defaultKeychain() {
        let cache = KeychainTokenCache(service: "com.example.mytool", account: "token")
        #expect((cache.keychain as? SystemKeychain)?.dataProtection == false)
    }

    @Test("Nothing saved loads as nil")
    func empty() async throws {
        #expect(try await cache.load() == nil)
    }

    @Test("A saved token loads back, and saving again replaces it")
    func roundTrip() async throws {
        try await cache.save("first")
        try await cache.save("second")
        #expect(try await cache.load() == "second")
    }

    @Test("Clearing forgets the token, and clearing when there is none does nothing")
    func clear() async throws {
        try await cache.save("token")
        try await cache.clear()
        #expect(try await cache.load() == nil)
        try await cache.clear()
    }

    @Test("It is kept as a device-only item under the service and account given")
    func item() async throws {
        try await cache.save("token")
        let item = KeychainItem(service: "com.example.mytool", account: "token")
        #expect(try keychain.data(for: item) == Data("token".utf8))
        #expect(item.accessibility == .afterFirstUnlockThisDeviceOnly)
    }

    @Test("An empty token is refused, as FileTokenCache refuses it")
    func emptyToken() async {
        await #expect(throws: KeychainError.malformed("the token is empty")) { try await cache.save("") }
    }

    @Test("A stored item that isn't text is refused, not read as signed out")
    func notText() async throws {
        try keychain.store(Data([0xFF, 0xFE, 0xFD]), as: KeychainItem(service: "com.example.mytool", account: "token"))
        await #expect(throws: KeychainError.malformed("the stored token is not UTF-8 text")) { try await cache.load() }
    }

    @Test("A stored empty item loads as nil, as an empty token file does")
    func storedEmpty() async throws {
        try keychain.store(Data(), as: KeychainItem(service: "com.example.mytool", account: "token"))
        #expect(try await cache.load() == nil)
    }
}
#endif
