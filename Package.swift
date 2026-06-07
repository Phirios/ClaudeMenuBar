// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AILimitCounter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AILimitCounter",
            path: "AILimitCounter"
        )
    ]
)
