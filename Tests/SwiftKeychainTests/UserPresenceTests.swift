// UserPresenceTests.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-28.

import Foundation
import LocalAuthentication
import os
import Security
import Testing
@testable import SwiftKeychain

/// Items that ask for the person before they are read. A real prompt can't be tested here: the
/// runner is unsigned, and the data-protection keychain, the only one that honours access control,
/// refuses an unsigned process's stores. So the rules are tested in both stores, the in-memory
/// store's prompt through its closure, and what `SystemKeychain` sends through the queries it builds.
@Suite("User presence")
struct UserPresenceTests {

    private static func item(prompt: String? = "Unlock the signing key") -> KeychainItem {
        KeychainItem(service: "com.swiftkeychain.tests.\(UUID().uuidString)", account: "ada",
                     requiresUserPresence: true, presencePrompt: prompt)
    }

    /// Counts the prompts an in-memory store shows, and answers each with `answer`.
    private final class Prompter: Sendable {
        let answer: InMemoryKeychain.Presence
        private let prompts = OSAllocatedUnfairLock(initialState: [String]())
        init(_ answer: InMemoryKeychain.Presence) { self.answer = answer }
        var shown: [String] { prompts.withLock { $0 } }
        func ask(_ prompt: String) -> InMemoryKeychain.Presence {
            prompts.withLock { $0.append(prompt) }
            return answer
        }
    }

    @Test("A new item doesn't ask for the person, and has no prompt")
    func defaults() {
        let item = KeychainItem(service: "s", account: "a")
        #expect(!item.requiresUserPresence)
        #expect(item.presencePrompt == nil)
    }

    @Test("An item that asks for the person can't synchronize")
    func noSync() {
        var item = Self.item()
        item.accessibility = .afterFirstUnlock
        item.synchronizable = true
        #expect(throws: KeychainError.malformed("an item that asks for the person can't synchronize")) {
            try InMemoryKeychain().store(Data("secret".utf8), as: item)
        }
    }

    @Test("An item that asks for the person needs a prompt that says why", arguments: [nil, "", "  "])
    func needsPrompt(_ prompt: String?) {
        #expect(throws: KeychainError.malformed("an item that asks for the person needs a prompt saying why")) {
            try InMemoryKeychain().store(Data("secret".utf8), as: Self.item(prompt: prompt))
        }
    }

    @Test("Reading asks once, with the item's prompt, and returns the data when the person is there")
    func granted() throws {
        let prompter = Prompter(.granted)
        let keychain = InMemoryKeychain(presence: prompter.ask)
        let item = Self.item()
        try keychain.store(Data("secret".utf8), as: item)
        #expect(prompter.shown.isEmpty)
        #expect(try keychain.data(for: item) == Data("secret".utf8))
        #expect(prompter.shown == ["Unlock the signing key"])
    }

    @Test("A dismissed prompt is cancelled, and a failed one is authenticationFailed")
    func refused() throws {
        for (answer, error) in [(InMemoryKeychain.Presence.cancelled, KeychainError.cancelled),
                                (.failed, .authenticationFailed)] {
            let keychain = InMemoryKeychain(presence: Prompter(answer).ask)
            let item = Self.item()
            try keychain.store(Data("secret".utf8), as: item)
            #expect(throws: error) { try keychain.data(for: item) }
        }
    }

    @Test("Replacing an item that asks for the person asks; adding one doesn't")
    func replaceAsks() throws {
        let prompter = Prompter(.cancelled)
        let keychain = InMemoryKeychain(presence: prompter.ask)
        let item = Self.item()
        #expect(try keychain.add(Data("first".utf8), as: item))
        #expect(prompter.shown.isEmpty)
        #expect(throws: KeychainError.cancelled) { try keychain.store(Data("second".utf8), as: item) }
    }

    @Test("An item that doesn't ask for the person never prompts")
    func plainNeverAsks() throws {
        let prompter = Prompter(.cancelled)
        let keychain = InMemoryKeychain(presence: prompter.ask)
        let item = KeychainItem(service: "s", account: "a")
        try keychain.store(Data("one".utf8), as: item)
        try keychain.store(Data("two".utf8), as: item)
        #expect(try keychain.data(for: item) == Data("two".utf8))
        #expect(prompter.shown.isEmpty)
    }

    /// Storing it without the protection asked for would be worse than refusing.
    @Test("The login keychain refuses an item that asks for the person")
    func loginKeychainRefuses() {
        let keychain = SystemKeychain(dataProtection: false)
        let refusal = KeychainError.malformed("the login keychain can't ask for the person; use the data-protection keychain")
        #expect(throws: refusal) { try keychain.store(Data("secret".utf8), as: Self.item()) }
        #expect(throws: refusal) { try keychain.data(for: Self.item()) }
    }

    @Test("SystemKeychain stores a presence item under access control, not a bare accessibility class")
    func addAttributes() throws {
        let attributes = try SystemKeychain().addAttributes(for: Self.item(), data: Data("secret".utf8))
        let control = try #require(attributes[kSecAttrAccessControl as String] as CFTypeRef?)
        #expect(CFGetTypeID(control) == SecAccessControlGetTypeID())
        #expect(attributes[kSecAttrAccessible as String] == nil)

        let plain = try SystemKeychain().addAttributes(for: KeychainItem(service: "s", account: "a"), data: Data())
        #expect(plain[kSecAttrAccessControl as String] == nil)
        #expect(plain[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test("SystemKeychain reads a presence item with a context carrying the prompt")
    func readQuery() throws {
        let query = try SystemKeychain().readQuery(for: Self.item())
        let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(context.localizedReason == "Unlock the signing key")

        let plain = try SystemKeychain().readQuery(for: KeychainItem(service: "s", account: "a"))
        #expect(plain[kSecUseAuthenticationContext as String] == nil)
    }

    @Test("A dismissed prompt and a failed one each have their own error")
    func statuses() {
        #expect(SystemKeychain.error(for: errSecUserCanceled) == .cancelled)
        #expect(SystemKeychain.error(for: errSecAuthFailed) == .authenticationFailed)
        #expect(SystemKeychain.error(for: errSecInteractionNotAllowed) == .locked)
        #expect(SystemKeychain.error(for: errSecMissingEntitlement) == .missingEntitlement)
        #expect(SystemKeychain.error(for: errSecParam) == .status(errSecParam))
    }
}
