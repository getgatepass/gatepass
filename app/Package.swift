// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GatePass",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GatePass",
            path: "Sources/GatePass"
        )
    ],
    swiftLanguageVersions: [.v5]
)
