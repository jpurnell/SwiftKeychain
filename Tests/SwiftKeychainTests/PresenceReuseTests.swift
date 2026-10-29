// PresenceReuseTests.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-28.

import Foundation
import LocalAuthentication
import os
import Security
import Testing
@testable import SwiftKeychain

/// One prompt for a burst of reads. That the Keychain really skips the second prompt for an
/// authenticated `LAContext` can't be tested here: the runner is unsigned, so presence items can't be
/// stored. What is tested is the rule in both stores: the in-memory store's prompts, and which context
/// `SystemKeychain` hands each read and what its queries carry.
@Suite("Presence reuse")
struct PresenceReuseTests {

    private static func item(_ prompt: String = "Sign the release") -> KeychainItem {
        KeychainItem(service: "com.swiftkeychain.tests.\(UUID().uuidString)", account: "ada",
                     requiresUserPresence: true, presencePrompt: prompt)
    }

    /// A clock a test moves by hand.
    private final class Clock: Sendable {
        private let start = ContinuousClock.now
        private let offset = OSAllocatedUnfairLock(initialState: Duration.zero)
        func advance(_ by: Duration) { offset.withLock { $0 += by } }
        func now() -> ContinuousClock.Instant { start + offset.withLock { $0 } }
    }

    /// Counts the prompts shown, answering each with the next of `answers` (the last repeats).
    private final class Prompter: Sendable {
        private let state: OSAllocatedUnfairLock<(answers: [InMemoryKeychain.Presence], shown: [String])>
        init(_ answers: InMemoryKeychain.Presence...) { state = .init(initialState: (answers, [])) }
        var shown: [String] { state.withLock { $0.shown } }
        func ask(_ prompt: String) -> InMemoryKeychain.Presence {
            state.withLock { state in
                state.shown.append(prompt)
                return state.answers.count > 1 ? state.answers.removeFirst() : state.answers.first ?? .granted
            }
        }
    }

    // MARK: - InMemoryKeychain

    @Test("Without reuse, each read asks")
    func offByDefault() throws {
        let prompter = Prompter(.granted)
        let keychain = InMemoryKeychain(presence: prompter.ask)
        let item = Self.item()
        try keychain.store(Data("key".utf8), as: item)
        _ = try keychain.data(for: item)
        _ = try keychain.data(for: item)
        #expect(prompter.shown.count == 2)
        #expect(keychain.presenceReuse == nil)
    }

    @Test("Within the window, a burst of reads asks once, with the first read's prompt")
    func burstAsksOnce() throws {
        let prompter = Prompter(.granted)
        let clock = Clock()
        let keychain = InMemoryKeychain(presence: prompter.ask, presenceReuse: .seconds(30), now: clock.now)
        let key = Self.item("Sign the release")
        let token = Self.item("Notarise the release")
        try keychain.store(Data("key".utf8), as: key)
        try keychain.store(Data("token".utf8), as: token)

        #expect(try keychain.data(for: key) == Data("key".utf8))
        clock.advance(.seconds(10))
        #expect(try keychain.data(for: token) == Data("token".utf8))
        #expect(try keychain.data(for: key) == Data("key".utf8))
        #expect(prompter.shown == ["Sign the release"])
    }

    @Test("After the window, the next read asks again")
    func windowEnds() throws {
        let prompter = Prompter(.granted)
        let clock = Clock()
        let keychain = InMemoryKeychain(presence: prompter.ask, presenceReuse: .seconds(30), now: clock.now)
        let item = Self.item()
        try keychain.store(Data("key".utf8), as: item)
        _ = try keychain.data(for: item)
        clock.advance(.seconds(31))
        _ = try keychain.data(for: item)
        #expect(prompter.shown.count == 2)
    }

    @Test("The window doesn't slide: reads inside it don't extend it")
    func noSliding() throws {
        let prompter = Prompter(.granted)
        let clock = Clock()
        let keychain = InMemoryKeychain(presence: prompter.ask, presenceReuse: .seconds(30), now: clock.now)
        let item = Self.item()
        try keychain.store(Data("key".utf8), as: item)
        _ = try keychain.data(for: item)
        clock.advance(.seconds(20))
        _ = try keychain.data(for: item)
        clock.advance(.seconds(20))
        _ = try keychain.data(for: item)
        #expect(prompter.shown.count == 2)
    }

    @Test("A refused prompt opens no window", arguments: [InMemoryKeychain.Presence.cancelled, .failed])
    func refusalOpensNothing(_ refusal: InMemoryKeychain.Presence) throws {
        let prompter = Prompter(refusal, .granted)
        let keychain = InMemoryKeychain(presence: prompter.ask, presenceReuse: .seconds(30))
        let item = Self.item()
        try keychain.store(Data("key".utf8), as: item)
        #expect(throws: KeychainError.self) { try keychain.data(for: item) }
        _ = try keychain.data(for: item)
        _ = try keychain.data(for: item)
        #expect(prompter.shown.count == 2)
    }

    @Test("Ending reuse makes the next read ask")
    func endReuse() throws {
        let prompter = Prompter(.granted)
        let keychain = InMemoryKeychain(presence: prompter.ask, presenceReuse: .seconds(30))
        let item = Self.item()
        try keychain.store(Data("key".utf8), as: item)
        _ = try keychain.data(for: item)
        keychain.endPresenceReuse()
        _ = try keychain.data(for: item)
        #expect(prompter.shown.count == 2)
    }

    @Test("A replace inside the window doesn't ask")
    func replaceInWindow() throws {
        let prompter = Prompter(.granted)
        let keychain = InMemoryKeychain(presence: prompter.ask, presenceReuse: .seconds(30))
        let item = Self.item()
        try keychain.store(Data("first".utf8), as: item)
        _ = try keychain.data(for: item)
        try keychain.store(Data("second".utf8), as: item)
        #expect(try keychain.data(for: item) == Data("second".utf8))
        #expect(prompter.shown.count == 1)
    }

    @Test("Concurrent reads in a burst ask once")
    func concurrentBurst() async throws {
        let prompter = Prompter(.granted)
        let keychain = InMemoryKeychain(presence: prompter.ask, presenceReuse: .seconds(30))
        let item = Self.item()
        try keychain.store(Data("key".utf8), as: item)
        try await withThrowingTaskGroup(of: Data?.self) { group in
            for _ in 0..<8 { group.addTask { try keychain.data(for: item) } }
            for try await data in group { #expect(data == Data("key".utf8)) }
        }
        #expect(prompter.shown.count == 1)
    }

    @Test("The window is capped at five minutes, and zero or less means none",
          arguments: [(Duration.seconds(600), Duration.seconds(300)), (.seconds(300), .seconds(300)),
                      (.seconds(30), .seconds(30)), (.zero, nil), (.seconds(-1), nil)] as [(Duration, Duration?)])
    func clamped(_ asked: Duration, _ inForce: Duration?) {
        #expect(SystemKeychain.maximumPresenceReuse == .seconds(300))
        #expect(InMemoryKeychain(presenceReuse: asked).presenceReuse == inForce)
        #expect(SystemKeychain(presenceReuse: asked).presenceReuse == inForce)
    }

    // MARK: - SystemKeychain

    @Test("SystemKeychain asks for the person on each read by default")
    func systemOffByDefault() {
        #expect(SystemKeychain().presenceReuse == nil)
    }

    /// What a session hands a call: the context's identity and the prompt it carries. A context
    /// that has been freed can leave its address to the next, so identity shows only sameness; a
    /// new context shows itself by carrying the new read's prompt.
    private struct Handed: Sendable, Equatable {
        let context: ObjectIdentifier
        let prompt: String
    }

    private static func hand(_ session: PresenceSession, _ prompt: String,
                             answer: @escaping @Sendable (Handed) -> PresenceOutcome<Handed> = { .confirmed($0) })
        throws -> Handed {
        let outcome: Handed? = try session.asking(prompt: prompt) { context in
            guard let context = context as? LAContext else { return .refused(.malformed("no context")) }
            return answer(Handed(context: ObjectIdentifier(context), prompt: context.localizedReason))
        }
        return try #require(outcome)
    }

    @Test("Within the window, each read is handed the first read's context and prompt")
    func sessionReuses() throws {
        let clock = Clock()
        let session = PresenceSession(length: .seconds(30), now: clock.now)
        let first = try Self.hand(session, "Sign the release")
        clock.advance(.seconds(29))
        let second = try Self.hand(session, "Notarise the release")
        #expect(second == first)
        #expect(second.prompt == "Sign the release")
    }

    @Test("Without reuse, each read gets a context of its own")
    func sessionOff() throws {
        let session = PresenceSession(length: nil)
        let first = try Self.hand(session, "Sign the release")
        let second = try Self.hand(session, "Notarise the release")
        #expect(first.prompt == "Sign the release")
        #expect(second.prompt == "Notarise the release")
    }

    @Test("After the window, a read gets a new context with its own prompt")
    func sessionExpires() throws {
        let clock = Clock()
        let session = PresenceSession(length: .seconds(30), now: clock.now)
        let first = try Self.hand(session, "Sign the release")
        clock.advance(.seconds(30))
        let second = try Self.hand(session, "Notarise the release")
        #expect(first.prompt == "Sign the release")
        #expect(second.prompt == "Notarise the release")
    }

    @Test("A refused read, or one that found nothing, leaves no context to reuse")
    func sessionRefusedOrAbsent() throws {
        let session = PresenceSession(length: .seconds(30))
        #expect(throws: KeychainError.cancelled) {
            try Self.hand(session, "Sign the release") { _ in .refused(.cancelled) }
        }
        _ = try Self.hand(session, "Read the token") { .notAsked($0) }
        let next = try Self.hand(session, "Notarise the release")
        #expect(next.prompt == "Notarise the release")
    }

    @Test("Ending reuse gives the next read a new context")
    func sessionEnds() throws {
        let keychain = SystemKeychain(presenceReuse: .seconds(30))
        let first = try Self.hand(keychain.session, "Sign the release")
        keychain.endPresenceReuse()
        let second = try Self.hand(keychain.session, "Notarise the release")
        #expect(first.prompt == "Sign the release")
        #expect(second.prompt == "Notarise the release")
    }

    @Test("Copies of a SystemKeychain share one window")
    func copiesShare() throws {
        let keychain = SystemKeychain(presenceReuse: .seconds(30))
        let copy = keychain
        let first = try Self.hand(keychain.session, "Sign the release")
        let second = try Self.hand(copy.session, "Notarise the release")
        #expect(second == first)
    }

    @Test("A read query carries the context it is given")
    func queryCarriesContext() throws {
        let context = LAContext()
        let query = SystemKeychain().readQuery(for: Self.item(), context: context)
        let carried = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(carried === context)
        #expect(query[kSecReturnData as String] as? Bool == true)
    }

    /// The unsigned runner can't store a presence item, so a read through the window finds nothing;
    /// it must come back `nil`, not an error, and leave nothing to reuse.
    @Test("A read through the window that finds nothing is nil")
    func systemReadAbsent() throws {
        let keychain = SystemKeychain(presenceReuse: .seconds(30))
        #expect(try keychain.data(for: Self.item()) == nil)
    }
}
