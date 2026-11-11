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
    .testTarget(
      name: "WicketTests", dependencies: ["WicketApp"], resources: [.copy("Fixtures")]
    ),
  ]
)
