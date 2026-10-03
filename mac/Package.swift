// swift-tools-version: 6.0
// Orbit for Mac: a native window and menu bar app for the Orbit server that runs on this Mac.
// Build the app bundle with ./build.sh
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Orbit",
            path: "Sources/Orbit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
