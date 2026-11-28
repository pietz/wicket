// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "GlassLab",
  platforms: [.macOS(.v27)],
  targets: [
    .target(name: "ObjCBoundary"),
    .executableTarget(name: "GlassLab", dependencies: ["ObjCBoundary"]),
  ]
)
