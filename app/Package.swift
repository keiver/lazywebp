// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ToWebP",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "ToWebP",
            path: "Sources/ToWebP"
        )
    ]
)
