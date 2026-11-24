// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BarFold",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BarFold", targets: ["BarFold"]),
        .executable(name: "barfoldctl", targets: ["BarFoldCLI"]),
        .library(name: "BarFoldProtocol", targets: ["BarFoldProtocol"]),
    ],
    dependencies: [
        // Sparkle 2 drives in-place updates: appcast discovery, EdDSA
        // verification, delta application and the standard update UI.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(
            name: "BarFoldProtocol",
            path: "Sources/BarFoldProtocol"
        ),
        .executableTarget(
            name: "BarFold",
            dependencies: [
                "BarFoldProtocol",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/BarFoldApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BarFoldCLI",
            dependencies: ["BarFoldProtocol"],
            path: "Sources/BarFoldCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BarFoldTests",
            dependencies: ["BarFoldProtocol"],
            path: "Tests/BarFoldTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
