// KeychainKeyTests.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-27.

import Foundation
import os
import Testing
import SwiftKeychain

/// A store whose every call fails the same way, for the paths a real Keychain takes only when
/// the device is locked or the entitlement is missing.
private struct RefusingKeychain: KeychainAccess {
    let error: KeychainError
    func data(for item: KeychainItem) throws(KeychainError) -> Data? { throw error }
    func store(_ data: Data, as item: KeychainItem) throws(KeychainError) { throw error }
    func delete(_ item: KeychainItem) throws(KeychainError) { throw error }
    func accounts(service: String) throws(KeychainError) -> [String] { throw error }
}

/// Another launch of the same app, storing its own new key just after this one read and found
/// none: the race two processes run when both start before either has a key.
private final class RacedKeychain: KeychainAccess {
    let store = InMemoryKeychain()
    let theirs: Data
    private let raced = OSAllocatedUnfairLock(initialState: false)

    init(theirs: Data) { self.theirs = theirs }

    func data(for item: KeychainItem) throws(KeychainError) -> Data? {
        let found = try store.data(for: item)
        let first = raced.withLock { done in defer { done = true }; return !done }
        if first { try store.store(theirs, as: item) }
        return found
    }
    func store(_ data: Data, as item: KeychainItem) throws(KeychainError) { try store.store(data, as: item) }
    func add(_ data: Data, as item: KeychainItem) throws(KeychainError) -> Bool { try store.add(data, as: item) }
    func delete(_ item: KeychainItem) throws(KeychainError) { try store.delete(item) }
    func accounts(service: String) throws(KeychainError) -> [String] { try store.accounts(service: service) }
}

/// A store that implements only the four calls 0.1.0 required, so `add` is the protocol's default.
private struct BasicKeychain: KeychainAccess {
    let store = InMemoryKeychain()
    func data(for item: KeychainItem) throws(KeychainError) -> Data? { try store.data(for: item) }
    func store(_ data: Data, as item: KeychainItem) throws(KeychainError) { try store.store(data, as: item) }
    func delete(_ item: KeychainItem) throws(KeychainError) { try store.delete(item) }
    func accounts(service: String) throws(KeychainError) -> [String] { try store.accounts(service: service) }
}

@Suite("KeychainKey")
struct KeychainKeyTests {

    private let item = KeychainItem(service: "com.swiftkeychain.tests", account: "sealing-key")

    @Test("A missing key is created, 32 bytes, and stored before it is returned")
    func creates() throws {
        let keychain = InMemoryKeychain()
        let key = try KeychainKey.loadOrCreate(item, using: keychain)
        #expect(key.count == KeychainKey.byteCount)
        #expect(KeychainKey.byteCount == 32)
        #expect(try keychain.data(for: item) == key)
    }

    @Test("A stored key is returned as it is, on every later call")
    func loads() throws {
        let keychain = InMemoryKeychain()
        let first = try KeychainKey.loadOrCreate(item, using: keychain)
        #expect(try KeychainKey.loadOrCreate(item, using: keychain) == first)
    }

    @Test("Two new keys differ, and neither is all zeros")
    func random() throws {
        let one = try KeychainKey.loadOrCreate(item, using: InMemoryKeychain())
        let two = try KeychainKey.loadOrCreate(item, using: InMemoryKeychain())
        #expect(one != two)
        #expect(one != Data(count: KeychainKey.byteCount))
    }

    /// Replacing a key of the wrong size would mint a new one and quietly make everything sealed
    /// with the old one unreadable, which reaches the person as an unexplained sign-out.
    @Test("A stored item of the wrong size is refused, and left as it was")
    func malformed() throws {
        let keychain = InMemoryKeychain()
        try keychain.store(Data(count: 16), as: item)
        #expect(throws: KeychainError.malformed("the stored key is 16 bytes, not 32")) {
            try KeychainKey.loadOrCreate(item, using: keychain)
        }
        #expect(try keychain.data(for: item) == Data(count: 16))
    }

    /// Replacing theirs would leave the other launch holding a key that is no longer stored,
    /// and whatever it sealed with it unreadable.
    @Test("A key another launch stored first is the one returned, and it is left in place")
    func raced() throws {
        let theirs = Data(repeating: 7, count: KeychainKey.byteCount)
        let keychain = RacedKeychain(theirs: theirs)
        #expect(try KeychainKey.loadOrCreate(item, using: keychain) == theirs)
        #expect(try keychain.data(for: item) == theirs)
    }

    @Test("A store without its own add gets one that leaves an existing item alone")
    func defaultAdd() throws {
        let keychain = BasicKeychain()
        #expect(try keychain.add(Data("first".utf8), as: item))
        #expect(try keychain.add(Data("second".utf8), as: item) == false)
        #expect(try keychain.data(for: item) == Data("first".utf8))
    }

    @Test("A locked keychain throws, rather than minting a key that would replace the real one")
    func locked() {
        #expect(throws: KeychainError.locked) {
            try KeychainKey.loadOrCreate(item, using: RefusingKeychain(error: .locked))
        }
    }
}
