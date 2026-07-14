// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Rdio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Rdio")
    ]
)
