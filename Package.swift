// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "osaurus-telegram",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "osaurus-telegram", type: .dynamic, targets: ["osaurus_telegram"])
    ],
    targets: [
        .target(
            name: "osaurus_telegram",
            path: "Sources/osaurus_telegram"
        ),
        .testTarget(
            name: "osaurus_telegram_tests",
            dependencies: ["osaurus_telegram"],
            path: "Tests/osaurus_telegram_tests"
        ),
    ]
)