// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DiscMenuPlayer",
    platforms: [.tvOS(.v18)],
    products: [.library(name: "DiscMenuPlayer", type: .dynamic, targets: ["DiscMenuPlayer"])],
    dependencies: [
        .package(url: "https://github.com/brandomoore/AetherEngine",
                 revision: "7cd91ee1a55401d59ca385e247a5c6308b7d27ea", traits: []),
        // Preserve the host's root override of the engine's optional SMB package.
        .package(url: "https://github.com/thatcube/SMBClient.git",
                 revision: "5d5bceb6fa0833c98b0eecc676609c9476bd9423"),
    ],
    targets: [
        .target(name: "DiscMenuPlayer", dependencies: [
            .product(name: "AetherEngine", package: "AetherEngine"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
