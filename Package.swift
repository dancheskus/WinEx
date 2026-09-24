// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "WinEx",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "WinEx",
            path: "Sources/WinEx",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
