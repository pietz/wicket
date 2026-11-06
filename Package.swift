// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Wicket",
    platforms: [.macOS(.v26)],
    targets: [
        // Pure, Foundation-only logic (matching, ranking, usage). Unit-tested.
        .target(name: "WicketCore"),
        // The app: AppKit shell, panel, hotkey, app index.
        .executableTarget(name: "Wicket", dependencies: ["WicketCore"]),
        .testTarget(name: "WicketCoreTests", dependencies: ["WicketCore"]),
    ]
)
