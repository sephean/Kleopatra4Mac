// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kleo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Kleo",
            path: "Sources/Kleo"
        ),
    ]
)
