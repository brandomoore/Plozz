// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DiscMenuPlayer",
    platforms: [.tvOS(.v18)],
    products: [.library(name: "DiscMenuPlayer", type: .dynamic, targets: ["DiscMenuPlayer"])],
    dependencies: [
        .package(url: "https://github.com/brandomoore/AetherEngine",
                 revision: "5eacfcdc5b76f9c330336810c9adc6d30b673531", traits: []),
        // Preserve the host's root override of the engine's optional SMB package.
        .package(url: "https://github.com/thatcube/SMBClient.git",
                 revision: "c778237de5e2525a46005241dc5e7926703bddcf"),
    ],
    targets: [
        .target(name: "DiscMenuPlayer", dependencies: [
            .product(name: "AetherEngine", package: "AetherEngine"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
