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
        "ObjCBoundary",
      ],
      resources: [.process("Resources")]),
    // Catches the Objective-C exceptions private key-value calls can raise (`GlassBlur`).
    .target(name: "ObjCBoundary"),
    .executableTarget(name: "Wicket", dependencies: ["WicketApp"]),
    .executableTarget(name: "wicket-js", path: "Sources/WicketJS"),
    // The bundled extensions: one process per request. build-app.sh copies each binary into the app
    // with its manifest and source.
    .executableTarget(name: "calculator", path: "Sources/Extensions/calculator", exclude: ["wicket.json"]),
    .executableTarget(name: "units", path: "Sources/Extensions/units", exclude: ["wicket.json"]),
    .executableTarget(name: "weather", path: "Sources/Extensions/weather", exclude: ["wicket.json"]),
    .executableTarget(name: "window", path: "Sources/Extensions/window", exclude: ["wicket.json"]),
    .executableTarget(name: "shell", path: "Sources/Extensions/shell", exclude: ["wicket.json"]),
    .executableTarget(name: "calendar", path: "Sources/Extensions/calendar", exclude: ["wicket.json"]),
    .executableTarget(
      name: "caffeinate", path: "Sources/Extensions/caffeinate", exclude: ["wicket.json"]),
    .executableTarget(
      name: "links-search", path: "Sources/Extensions/links-search", exclude: ["wicket.json"]),
    .testTarget(
      name: "WicketTests",
      dependencies: ["WicketApp", "units", "weather", "window", "shell", "caffeinate", "calendar"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
