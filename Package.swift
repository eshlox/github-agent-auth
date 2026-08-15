// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "github-agent-auth",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "github-agent-auth", targets: ["GitHubAgentAuth"])
  ],
  targets: [.executableTarget(name: "GitHubAgentAuth")]
)
