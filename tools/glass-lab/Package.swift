// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "GlassLab",
  platforms: [.macOS(.v26)],
  targets: [
    .target(name: "ObjCBoundary"),
    .executableTarget(name: "GlassLab", dependencies: ["ObjCBoundary"]),
  ]
)
