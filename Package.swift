// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PRBar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "PRBar", path: "Sources/PRBar", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
