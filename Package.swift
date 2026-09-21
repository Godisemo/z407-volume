// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Z407Volume",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Z407Volume", path: "Sources/Z407Volume")
    ]
)
