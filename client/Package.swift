// swift-tools-version:5.9
import PackageDescription

// Sources live flat in this directory (client/), not under Sources/VortexClient,
// so the target path is "." with an explicit source list.
let package = Package(
  name: "VortexClient",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "VortexClient",
      path: ".",
      exclude: ["README.md", "run.sh"],
      sources: [
        "main.swift",
        "Renderer.swift",
        "Shaders.swift",
        "FieldClient.swift",
        "ControlPanel.swift"
      ]
    )
  ]
)
