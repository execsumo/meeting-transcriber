// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "audiotap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "audiotap",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
