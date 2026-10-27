// KeychainKey.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-27.

import Foundation
import Security

/// A 256-bit key kept in the Keychain: read if it is there, created if it isn't.
///
/// For a key that seals other secrets, such as swift-oauth's `EncryptedFileClientStorage`.
/// `SymmetricKey(data:)` takes what this returns.
public enum KeychainKey {

    /// The size of a key, in bytes: 32, for 256 bits.
    public static let byteCount = 32

    /// The key stored as `item`, or a new one, stored before it is returned.
    ///
    /// A stored item of the wrong size is refused, not replaced: a new key would make everything
    /// sealed with the old one unreadable, which reaches the person as an unexplained request to
    /// sign in again. Any error reading the item is thrown, so a locked device can't mint a key
    /// that replaces the real one.
    ///
    /// - Parameters:
    ///   - item: Where the key is kept.
    ///   - keychain: The store.
    /// - Returns: The key, ``byteCount`` bytes.
    /// - Throws: ``KeychainError``.
    public static func loadOrCreate(_ item: KeychainItem, using keychain: some KeychainAccess) throws(KeychainError) -> Data {
        if let stored = try keychain.data(for: item) {
            guard stored.count == byteCount else {
                throw .malformed("the stored key is \(stored.count) bytes, not \(byteCount)")
            }
            return stored
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else { throw .status(status) }
        let key = Data(bytes)
        try keychain.store(key, as: item)
        return key
    }
}
