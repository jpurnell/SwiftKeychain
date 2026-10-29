// PresenceReuse.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-28.

import Foundation
// tvOS has no LocalAuthentication, and watchOS can't give a prompt a reason; neither can ask for the person.
#if canImport(LocalAuthentication) && !os(watchOS)
import LocalAuthentication
#endif
#if canImport(os)
import os
#endif

/// How long one confirmation stands in for the prompts after it.
///
/// It opens when the person confirms and lasts ``length`` from then. Reads inside it don't extend
/// it, so a steady trickle of reads still asks again once it ends.
struct ReuseWindow: Sendable {

    /// How long the window lasts, after clamping; `nil` means each read asks.
    let length: Duration?
    /// When the open window ends; `nil` while it is closed.
    private var until: ContinuousClock.Instant?

    /// A closed window of the length asked for, capped at ``SystemKeychain/maximumPresenceReuse``;
    /// zero or less means no reuse.
    init(_ asked: Duration?) {
        if let asked, asked > .zero {
            length = min(asked, SystemKeychain.maximumPresenceReuse)
        } else {
            length = nil
        }
    }

    /// Whether a confirmation still stands at `now`.
    func isOpen(at now: ContinuousClock.Instant) -> Bool {
        guard let until else { return false }
        return now < until
    }

    /// Opens the window from `now`, the moment the person confirmed. Does nothing without reuse.
    mutating func open(at now: ContinuousClock.Instant) {
        guard let length else { return }
        until = now + length
    }

    /// Ends the window: the next read asks.
    mutating func close() {
        until = nil
    }
}

/// How a Keychain call that may ask for the person went.
enum PresenceOutcome<Value: Sendable>: Sendable {
    /// It succeeded, so the context it was given is now authenticated.
    case confirmed(Value)
    /// It found nothing, so nothing was asked and the context is no more authenticated than before.
    case notAsked(Value)
    /// It failed: the person said no, or the Keychain refused.
    case refused(KeychainError)

    /// The value, or the refusal thrown.
    func value() throws(KeychainError) -> Value {
        switch self {
        case .confirmed(let value), .notAsked(let value): return value
        case .refused(let error): throw error
        }
    }
}

/// An `LAContext` (or nothing, where the platform can't ask) held in ``PresenceSession``'s lock.
// Justification: LAContext isn't Sendable; this box is only ever read or invalidated while PresenceSession's lock is held, so no two threads touch the context at once.
final class HeldContext: @unchecked Sendable {

    /// The context, as `kSecUseAuthenticationContext` takes it.
    let context: AnyObject?

    /// Holds `context`.
    init(_ context: AnyObject?) {
        self.context = context
    }

    /// Ends the context's authentication, so nothing can reuse it.
    func invalidate() {
        #if canImport(LocalAuthentication) && !os(watchOS)
        (context as? LAContext)?.invalidate()
        #endif
    }
}

/// One authenticated context shared by the reads of a burst, for a bounded time.
///
/// The context never leaves the lock: each call that may ask runs inside it, so a concurrent burst
/// asks once (the second call waits for the first's answer), and no two threads use the context at
/// once. Calls for items that don't ask for the person never come here.
final class PresenceSession: Sendable {

    private struct State: Sendable {
        var window: ReuseWindow
        var held: HeldContext?
    }

    /// How long a confirmation stands, after clamping; `nil` means each read asks.
    let length: Duration?
    private let state: OSAllocatedUnfairLock<State>
    private let now: @Sendable () -> ContinuousClock.Instant

    /// A session whose window lasts `length`, clamped as ``ReuseWindow`` does.
    /// - Parameters:
    ///   - length: How long a confirmation stands; `nil` or zero for none.
    ///   - now: The time; the continuous clock's.
    init(length: Duration?, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        let window = ReuseWindow(length)
        self.length = window.length
        self.state = OSAllocatedUnfairLock(initialState: State(window: window, held: nil))
        self.now = now
    }

    /// Runs `call` with the context of the open window, or a new one carrying `prompt`; keeps a new
    /// one when the call confirms, and ends the window when a call is refused.
    /// - Parameters:
    ///   - prompt: The prompt for a new context. A reused context keeps the first read's.
    ///   - call: The Keychain call, given the context to send as `kSecUseAuthenticationContext`.
    /// - Returns: What the call returned.
    /// - Throws: The call's refusal.
    func asking<Value: Sendable>(
        prompt: String,
        _ call: @Sendable (AnyObject?) -> PresenceOutcome<Value>
    ) throws(KeychainError) -> Value {
        let outcome = state.withLock { state in
            let reused = state.window.isOpen(at: now()) ? state.held : nil
            if reused == nil { Self.end(&state) }
            let held = reused ?? HeldContext(SystemKeychain.context(prompt: prompt))
            let outcome = call(held.context)
            switch outcome {
            case .confirmed:
                guard reused == nil, length != nil else { break }
                state.held = held
                state.window.open(at: now())
            case .notAsked:
                break
            case .refused:
                Self.end(&state)
            }
            return outcome
        }
        return try outcome.value()
    }

    /// Ends the window and invalidates its context: the next read asks.
    func end() {
        state.withLock { Self.end(&$0) }
    }

    private static func end(_ state: inout State) {
        state.held?.invalidate()
        state.held = nil
        state.window.close()
    }
}
