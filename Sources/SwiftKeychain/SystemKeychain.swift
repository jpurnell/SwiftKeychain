// SystemKeychain.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-27.

import Foundation
// tvOS has no LocalAuthentication, and watchOS can't give a prompt a reason; neither can ask for the person.
#if canImport(LocalAuthentication) && !os(watchOS)
import LocalAuthentication
#endif
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
///
/// An item that asks for the person (``KeychainItem/requiresUserPresence``) is stored under access
/// control and needs the data-protection keychain. Reading it shows the system prompt with the
/// item's ``KeychainItem/presencePrompt``; replacing it may too; adding, deleting and listing don't.
///
/// By default each of those reads asks. With `presenceReuse`, one confirmation stands for the reads
/// and replaces after it, for a bounded time; see ``init(dataProtection:presenceReuse:)``.
public struct SystemKeychain: KeychainAccess {

    private static let logger = Logger(subsystem: "com.swiftkeychain", category: "SystemKeychain")

    /// Whether items go to the data-protection keychain. Ignored outside macOS, where there is no other.
    public let dataProtection: Bool

    /// The longest one confirmation can stand for the prompts after it: five minutes, the ceiling
    /// Apple sets for reusing a Touch ID unlock.
    public static let maximumPresenceReuse: Duration = .seconds(300)

    /// The confirmed context a burst of reads shares, and until when. Copies share it.
    let session: PresenceSession

    /// How long one confirmation stands for the prompts after it, as clamped; `nil` means each read
    /// asks. Always `nil` on tvOS and watchOS, which can't ask for the person.
    public var presenceReuse: Duration? { session.length }

    /// Creates an accessor.
    /// - Parameters:
    ///   - dataProtection: On macOS, use the data-protection keychain (`true`, for signed apps) or
    ///     the login keychain (`false`, for command-line tools).
    ///   - presenceReuse: How long the person's confirmation of one read of an item that asks for
    ///     them stands for the reads and replaces after it, so a burst asks once. `nil`, the default,
    ///     asks on every read. The window opens when they confirm and doesn't slide; it is capped at
    ///     ``maximumPresenceReuse``, and zero or less means none. Only the first read's prompt is
    ///     shown, so use it where the reads in a burst serve one act. A cancelled or failed prompt,
    ///     or any other error from such a call, ends it; so does ``endPresenceReuse()``. Copies of
    ///     this value share one window. Does nothing on tvOS and watchOS.
    public init(dataProtection: Bool = true, presenceReuse: Duration? = nil) {
        self.dataProtection = dataProtection
        self.session = PresenceSession(length: Self.canAskForPerson ? presenceReuse : nil)
    }

    /// Ends the window ``presenceReuse`` opened, so the next read asks, as at sign-out or
    /// "lock now". Does nothing if there is none.
    public func endPresenceReuse() {
        session.end()
    }

    /// The data stored as `item`.
    /// - Parameter item: The item to read.
    /// - Returns: The data, or `nil` if there is no such item.
    /// - Throws: ``KeychainError``.
    public func data(for item: KeychainItem) throws(KeychainError) -> Data? {
        try checkSupported(item)
        return try authenticating(item) { context in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(readQuery(for: item, context: context) as CFDictionary, &result)
            if status == errSecItemNotFound { return .notAsked(nil) }
            if let failure = Self.failure(status, doing: "read") { return .refused(failure) }
            guard let data = result as? Data else {
                return .refused(.malformed("the item's data was not returned as bytes"))
            }
            return .confirmed(data)
        }
    }

    /// Stores `data` as `item`, replacing whatever was there.
    /// - Parameters:
    ///   - data: The secret.
    ///   - item: Where it goes, and who may read it.
    /// - Throws: ``KeychainError``.
    public func store(_ data: Data, as item: KeychainItem) throws(KeychainError) {
        guard try !add(data, as: item) else { return }
        try authenticating(item) { context -> PresenceOutcome<Void> in
            var changes: [String: Any]
            do throws(KeychainError) {
                changes = try protection(of: item)
            } catch {
                return .refused(error)
            }
            changes.merge(labelAttributes(of: item)) { _, new in new }
            changes[kSecValueData as String] = data
            var query = identity(of: item)
            if let context {
                query[kSecUseAuthenticationContext as String] = context
            }
            let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            if let failure = Self.failure(status, doing: "update") { return .refused(failure) }
            return .confirmed(())
        }
    }

    /// Runs a call that may ask for the person: with no context for an item that doesn't ask; with
    /// a new one carrying the prompt when there's no reuse; through the session when there is.
    private func authenticating<Value: Sendable>(
        _ item: KeychainItem,
        _ call: @Sendable (AnyObject?) -> PresenceOutcome<Value>
    ) throws(KeychainError) -> Value {
        guard item.requiresUserPresence else { return try call(nil).value() }
        guard session.length != nil else { return try call(Self.context(prompt: item.prompt)).value() }
        return try session.asking(prompt: item.prompt, call)
    }

    /// Stores `data` as `item` only if nothing is stored there yet: one add, which the Keychain
    /// refuses as a duplicate if another process got there first.
    /// - Parameters:
    ///   - data: The secret.
    ///   - item: Where it goes, and who may read it.
    /// - Returns: `true` if this call stored it, `false` if an item was already there.
    /// - Throws: ``KeychainError``.
    public func add(_ data: Data, as item: KeychainItem) throws(KeychainError) -> Bool {
        let status = SecItemAdd(try addAttributes(for: item, data: data) as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        try Self.check(status, doing: "add")
        return true
    }

    /// Removes `item`, if it is there.
    /// - Parameter item: The item to remove.
    /// - Throws: ``KeychainError``.
    public func delete(_ item: KeychainItem) throws(KeychainError) {
        try checkSupported(item)
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
        // Listing names never needs the person; an item under access control mustn't prompt for it.
        query[kSecUseAuthenticationContext as String] = Self.silentContext()
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

    /// Refuses an item this keychain can't hold as asked: the item's own rules, and, in the
    /// login keychain, any item that asks for the person, which only the data-protection
    /// keychain can honour. Storing it without that protection would be worse than refusing.
    private func checkSupported(_ item: KeychainItem) throws(KeychainError) {
        try item.validate()
        guard Self.canAskForPerson || !item.requiresUserPresence else {
            throw .malformed("this platform can't ask for the person")
        }
        guard dataProtection || !item.requiresUserPresence else {
            throw .malformed("the login keychain can't ask for the person; use the data-protection keychain")
        }
    }

    /// What `add` sends: the item, its data, and its protection.
    func addAttributes(for item: KeychainItem, data: Data) throws(KeychainError) -> [String: Any] {
        try checkSupported(item)
        var attributes = identity(of: item)
        attributes.merge(try protection(of: item)) { _, new in new }
        attributes.merge(labelAttributes(of: item)) { _, new in new }
        attributes[kSecValueData as String] = data
        return attributes
    }

    /// What a read of `item` sends without reuse: for an item that asks for the person, with a new
    /// context that carries the prompt.
    func readQuery(for item: KeychainItem) throws(KeychainError) -> [String: Any] {
        try checkSupported(item)
        return readQuery(for: item, context: item.requiresUserPresence ? Self.context(prompt: item.prompt) : nil)
    }

    /// What a read of `item` sends, with `context`, if any, as its authentication context.
    func readQuery(for item: KeychainItem, context: AnyObject?) -> [String: Any] {
        var query = identity(of: item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        return query
    }

    /// The accessibility class, or, for an item that asks for the person, access control over
    /// that class. The Keychain takes one or the other, never both.
    private func protection(of item: KeychainItem) throws(KeychainError) -> [String: Any] {
        let accessible = Self.accessible(item.accessibility)
        guard item.requiresUserPresence else {
            return [kSecAttrAccessible as String: accessible]
        }
        guard let control = SecAccessControlCreateWithFlags(nil, accessible, .userPresence, nil) else {
            throw .malformed("the system could not create access control for user presence")
        }
        return [kSecAttrAccessControl as String: control]
    }

    /// What describes the item without picking it out: its label, when it has one. Sent on add
    /// and update, never in a query that finds an item.
    private func labelAttributes(of item: KeychainItem) -> [String: Any] {
        guard let label = item.label else { return [:] }
        return [kSecAttrLabel as String: label]
    }

    /// Whether this platform can ask for the person: not tvOS or watchOS.
    static var canAskForPerson: Bool {
        #if canImport(LocalAuthentication) && !os(watchOS)
        true
        #else
        false
        #endif
    }

    /// A context whose prompt says what the read is for; `nil` where the platform can't ask,
    /// which ``checkSupported(_:)`` has already refused.
    static func context(prompt: String) -> AnyObject? {
        #if canImport(LocalAuthentication) && !os(watchOS)
        let context = LAContext()
        context.localizedReason = prompt
        return context
        #else
        return nil
        #endif
    }

    /// A context that never prompts, for listing; `nil` where nothing can prompt anyway.
    private static func silentContext() -> AnyObject? {
        #if canImport(LocalAuthentication) && !os(watchOS)
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
        #else
        return nil
        #endif
    }

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

    /// Turns a status other than success into the error that names it, and logs it.
    private static func check(_ status: OSStatus, doing operation: String) throws(KeychainError) {
        if let failure = failure(status, doing: operation) { throw failure }
    }

    /// The error a status other than success names, logged; `nil` for success.
    private static func failure(_ status: OSStatus, doing operation: String) -> KeychainError? {
        guard status != errSecSuccess else { return nil }
        let failure = error(for: status)
        switch failure {
        case .locked, .cancelled:
            logger.notice("keychain \(operation, privacy: .public) refused: \(String(describing: failure), privacy: .public)")
        default:
            logger.error("keychain \(operation, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
        }
        return failure
    }

    /// The error a status other than success names.
    static func error(for status: OSStatus) -> KeychainError {
        switch status {
        case errSecInteractionNotAllowed: .locked
        case errSecMissingEntitlement: .missingEntitlement
        case errSecUserCanceled: .cancelled
        case errSecAuthFailed: .authenticationFailed
        default: .status(status)
        }
    }
}
