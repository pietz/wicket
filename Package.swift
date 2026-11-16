// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Wicket",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0"),
    // In-app updates for the released app (Updater).
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
  ],
  targets: [
    .target(
      name: "WicketApp",
      dependencies: [
        .product(name: "cmark-gfm", package: "swift-cmark"),
        .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      resources: [.process("Resources")]),
    .executableTarget(name: "Wicket", dependencies: ["WicketApp"]),
    // The bundled extensions: plain Swift without Foundation, one process per request. build-app.sh
    // copies each binary into the app with its manifest and source.
    .executableTarget(name: "calculator", path: "Sources/Extensions/calculator", exclude: ["wicket.json"]),
    .executableTarget(name: "units", path: "Sources/Extensions/units", exclude: ["wicket.json"]),
    .executableTarget(name: "window", path: "Sources/Extensions/window", exclude: ["wicket.json"]),
    // The window extension's geometry is tested as functions (`@testable import window`).
    .testTarget(
      name: "WicketTests", dependencies: ["WicketApp", "window"], resources: [.copy("Fixtures")]
    ),
  ]
)
