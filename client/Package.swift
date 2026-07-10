// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "VortexClient",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "VortexClient",
      path: "Sources/VortexClient"
    )
  ]
)
