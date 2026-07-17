// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "osaurus-telegram",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "osaurus-telegram", type: .dynamic, targets: ["osaurus_telegram"])
    ],
    dependencies: [
        // Pinned EXACTLY: the SDK mirrors the host's frozen ABI layout and
        // must move in lockstep with the reviewed host version.
        .package(url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "osaurus_telegram",
            dependencies: [
                .product(name: "OsaurusPluginABI", package: "osaurus-plugin-sdk"),
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
            ],
            path: "Sources/osaurus_telegram"
        ),
        .testTarget(
            name: "osaurus_telegram_tests",
            dependencies: [
                "osaurus_telegram",
                .product(name: "OsaurusPluginTestSupport", package: "osaurus-plugin-sdk"),
            ],
            path: "Tests/osaurus_telegram_tests"
        ),
    ]
)