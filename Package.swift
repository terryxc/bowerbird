// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bowerbird",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.1.0"),
    ],
    targets: [
        .target(
            name: "BowerbirdCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/BowerbirdCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Bowerbird",
            dependencies: [
                "BowerbirdCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Bowerbird",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BowerbirdTests",
            dependencies: ["Bowerbird"],
            path: "Tests/BowerbirdTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BowerbirdCoreTests",
            dependencies: ["BowerbirdCore"],
            path: "Tests/BowerbirdCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
