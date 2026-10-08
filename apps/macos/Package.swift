// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Geleit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Geleit",
            path: "Sources/Geleit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
