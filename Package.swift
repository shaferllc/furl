// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Furl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Furl",
            path: "Sources/Furl"
        ),
    ]
)
