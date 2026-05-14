// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SQLiteGraphStudio",
    platforms: [
        .macOS(.v15),
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
            name: "SampleBuilder",
            targets: ["SampleBuilder"]
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
            exclude: ["App/Info.plist"],
            resources: [
                .process("App/Assets.xcassets"),
            ]
        ),
        .executableTarget(
            name: "SampleBuilder",
            dependencies: ["StudioCore"],
            path: "Tools/SampleBuilder"
        ),
        .testTarget(
            name: "SQLiteGraphStudioTests",
            dependencies: ["StudioCore"],
            path: "Tests/SQLiteGraphStudioTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
