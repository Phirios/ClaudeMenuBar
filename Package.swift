// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeMenuBar",
            path: "ClaudeMenuBar"
        )
    ]
)
