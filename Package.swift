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
        ),
        // The app WinEx puts in the Dock for each folder stack (copied into its bundles)
        .executableTarget(
            name: "WinExStack",
            path: "Sources/WinExStack",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WinExTests",
            dependencies: ["WinEx"],
            path: "Tests/WinExTests",
            // Command Line Tools ship the Swift Testing macro plugin here, but don't always pass its path
            swiftSettings: [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]
        ),
    ]
)
