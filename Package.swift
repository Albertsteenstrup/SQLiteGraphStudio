// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SQLiteGraphStudio",
    platforms: [
        .macOS(.v15),
        .iOS(.v13),
    ],
    products: [
        .library(
            name: "StudioCore",
            targets: ["StudioCore"]
        ),
        .executable(
            name: "SQLiteGraphStudio",
            targets: ["SQLiteGraphStudio"]
        ),
        .executable(
            name: "FixtureBuilder",
            targets: ["FixtureBuilder"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    ],
    targets: [
        .target(
            name: "StudioCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/StudioCore"
        ),
        .executableTarget(
            name: "SQLiteGraphStudio",
            dependencies: ["StudioCore"],
            path: "Sources/SQLiteGraphStudio",
            resources: [
                .process("App/Assets.xcassets"),
            ]
        ),
        .executableTarget(
            name: "FixtureBuilder",
            dependencies: ["StudioCore"],
            path: "Tools/FixtureBuilder"
        ),
        .testTarget(
            name: "SQLiteGraphStudioTests",
            dependencies: ["StudioCore"],
            path: "Tests/SQLiteGraphStudioTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
