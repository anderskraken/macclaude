// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacClaude",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacClaude", targets: ["MacClaude"])],
    targets: [
        .target(name: "MacClaudeCore"),
        .executableTarget(name: "MacClaude", dependencies: ["MacClaudeCore"]),
        .testTarget(name: "MacClaudeCoreTests", dependencies: ["MacClaudeCore"]),
        .testTarget(name: "MacClaudeAppTests", dependencies: ["MacClaude", "MacClaudeCore"])
    ]
)
