// KeychainTokenCache.swift
// SwiftKeychain
// Created by Justin Purnell on 2026-10-27.

#if CLIAuth
import Foundation
import SwiftCLIKitAuth

/// swift-cli-kit-auth's `TokenCache`, kept as one Keychain item. Needs the `CLIAuth` trait.
///
/// A remembered token for a command-line tool, so the default store is the login keychain: an
/// unsigned tool can't use the data-protection keychain, and macOS may ask once to allow access.
///
/// ```swift
/// import SwiftKeychain
/// import SwiftCLIKitAuth
/// import SwiftIdentity
///
/// let cache = KeychainTokenCache(service: "com.example.mytool", account: "token")
/// // Wherever swift-cli-kit-auth's guide passes a FileTokenCache:
/// let remembered = RememberedToken(cache: cache, credential: BearerKey.init)
/// ```
///
/// The item stays on this device. An empty token is refused, and a stored item that isn't text
/// throws rather than reading as "signed out", as `FileTokenCache` does with its file.
public struct KeychainTokenCache: TokenCache {

    /// The item the token is kept as.
    public let item: KeychainItem

    /// The store.
    public let keychain: any KeychainAccess

    /// Creates a cache.
    /// - Parameters:
    ///   - service: The service the token is filed under, such as the tool's identifier.
    ///   - account: The account within the service.
    ///   - keychain: The store. Defaults to the login keychain.
    public init(service: String, account: String, keychain: any KeychainAccess = SystemKeychain(dataProtection: false)) {
        self.item = KeychainItem(service: service, account: account)
        self.keychain = keychain
    }

    /// The remembered token, or `nil` if there is none.
    /// - Throws: ``KeychainError``.
    public func load() async throws -> String? {
        guard let data = try keychain.data(for: item), !data.isEmpty else { return nil }
        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.malformed("the stored token is not UTF-8 text")
        }
        return token
    }

    /// Remembers a token, replacing any before it.
    /// - Parameter token: The token, exactly as the sign-in flow returned it.
    /// - Throws: ``KeychainError``.
    public func save(_ token: String) async throws {
        guard !token.isEmpty else { throw KeychainError.malformed("the token is empty") }
        try keychain.store(Data(token.utf8), as: item)
    }

    /// Forgets the token. Forgetting when there is none does nothing.
    /// - Throws: ``KeychainError``.
    public func clear() async throws {
        try keychain.delete(item)
    }
}
#endif
