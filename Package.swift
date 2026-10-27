// swift-tools-version: 6.2

import PackageDescription

// Tokens and keys in the Apple Keychain.
//
// The core depends on Foundation and Security only. The conformances for swift-oauth and
// swift-cli-kit-auth sit behind traits, off by default: SwiftPM resolves every package-level
// dependency an enabled trait names and none that a disabled trait names, so an app that wants
// only the core downloads nothing else.
let package = Package(
    name: "SwiftKeychain",
    platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "SwiftKeychain", targets: ["SwiftKeychain"]),
    ],
    traits: [
        .trait(name: "OAuth", description: "KeychainClientStorage, for swift-oauth's OAuthClientStorage."),
        .trait(name: "CLIAuth", description: "KeychainTokenCache, for swift-cli-kit-auth's TokenCache."),
    ],
    dependencies: [
        .package(url: "https://github.com/jpurnell/swift-oauth.git", from: "1.0.0-beta.9"),
        .package(url: "https://github.com/jpurnell/swift-cli-kit-auth.git", from: "0.4.0"),
        // For `swift package generate-documentation`. No target links it, so a package that
        // depends on this one doesn't resolve it.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
    ],
    targets: [
        .target(
            name: "SwiftKeychain",
            dependencies: [
                .product(name: "SwiftOAuthClient", package: "swift-oauth", condition: .when(traits: ["OAuth"])),
                .product(name: "SwiftCLIKitAuth", package: "swift-cli-kit-auth", condition: .when(traits: ["CLIAuth"])),
            ]
        ),
        .testTarget(
            name: "SwiftKeychainTests",
            dependencies: [
                "SwiftKeychain",
                .product(name: "SwiftOAuthClient", package: "swift-oauth", condition: .when(traits: ["OAuth"])),
                .product(name: "SwiftCLIKitAuth", package: "swift-cli-kit-auth", condition: .when(traits: ["CLIAuth"])),
            ]
        ),
    ]
)
