// KeychainClientStorage.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-27.

#if OAuth
import Foundation
import SwiftOAuthClient

/// swift-oauth's `OAuthClientStorage`, one Keychain item per connection. Needs the `OAuth` trait.
///
/// ```swift
/// import SwiftKeychain
///
/// let storage = KeychainClientStorage(service: "com.example.app.oauth")
/// ```
///
/// Every item stays on this device and never synchronizes. A rotating refresh token copied to a
/// second device is presented twice; the provider sees the reuse and revokes the whole token
/// family, signing the person out everywhere. So there is no option to sync these.
///
/// Each item's account name is the `ConnectionID` as JSON with sorted keys, so the same
/// connection always names the same item, and a `/` inside a field can't be mistaken for the
/// separator that `ConnectionID.description` uses. A rotation replaces the item in one call.
///
/// The default store is the data-protection keychain, for signed apps. An item that doesn't
/// decode throws rather than reading as "not connected", which would send the person to
/// authorize again and overwrite what may be a recoverable credential.
public struct KeychainClientStorage: OAuthClientStorage {

    /// The service every connection's item is filed under.
    public let service: String

    /// The store.
    public let keychain: any KeychainAccess

    /// Creates a store.
    /// - Parameters:
    ///   - service: The service the credentials are filed under, such as the app's identifier.
    ///   - keychain: The store. Defaults to the data-protection keychain.
    public init(service: String, keychain: any KeychainAccess = SystemKeychain()) {
        self.service = service
        self.keychain = keychain
    }

    /// The credential for a connection, if one is stored.
    /// - Parameter connection: The connection.
    /// - Returns: The credential, or `nil` if none is stored.
    /// - Throws: ``KeychainError``.
    public func credential(for connection: ConnectionID) async throws -> StoredCredential? {
        guard let data = try keychain.data(for: try item(for: connection)) else { return nil }
        do {
            return try JSONDecoder().decode(StoredCredential.self, from: data)
        } catch {
            throw KeychainError.malformed("the stored credential for \(connection) doesn't decode")
        }
    }

    /// Stores a credential, replacing any previous one for the same connection.
    /// - Parameters:
    ///   - credential: The credential.
    ///   - connection: The connection it belongs to.
    /// - Throws: ``KeychainError``, so a write that didn't happen is never taken for one that did.
    public func store(_ credential: StoredCredential, for connection: ConnectionID) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credential)
        } catch {
            throw KeychainError.malformed("the credential for \(connection) doesn't encode")
        }
        try keychain.store(data, as: try item(for: connection))
    }

    /// Forgets a connection. This does not revoke anything at the provider.
    /// - Parameter connection: The connection.
    /// - Throws: ``KeychainError``.
    public func remove(_ connection: ConnectionID) async throws {
        try keychain.delete(try item(for: connection))
    }

    /// Every connection with a stored credential.
    /// - Returns: The connections, in the order of their account names.
    /// - Throws: ``KeychainError``, including for an account under the service that isn't a connection.
    public func connections() async throws -> [ConnectionID] {
        try keychain.accounts(service: service).map { account in
            do {
                return try JSONDecoder().decode(ConnectionID.self, from: Data(account.utf8))
            } catch {
                throw KeychainError.malformed("an item under \(service) isn't a connection")
            }
        }
    }

    /// The device-only item a connection's credential is kept as.
    private func item(for connection: ConnectionID) throws -> KeychainItem {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let account: Data
        do {
            account = try encoder.encode(connection)
        } catch {
            throw KeychainError.malformed("the connection \(connection) doesn't encode")
        }
        return KeychainItem(service: service, account: String(decoding: account, as: UTF8.self))
    }
}
#endif
