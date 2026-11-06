// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Wicket",
    platforms: [.macOS(.v26)],
    targets: [
        // Pure, Foundation-only logic (matching, ranking, usage). Unit-tested.
        .target(name: "WicketCore"),
        // Runs extensions: processes, sessions, the checker. Shared by the app and the CLI.
        .target(name: "WicketHost", dependencies: ["WicketCore"]),
        // The app: AppKit shell, panel, hotkey, app index.
        .executableTarget(name: "Wicket", dependencies: ["WicketCore", "WicketHost"]),
        // The `wicket` command-line tool, bundled at Wicket.app/Contents/Helpers/wicket.
        .executableTarget(name: "WicketCLI", dependencies: ["WicketCore", "WicketHost"]),
        .testTarget(name: "WicketCoreTests", dependencies: ["WicketCore"]),
        // Fixtures holds recorded agent streams, replayed by a fake agent executable.
        .testTarget(name: "WicketHostTests", dependencies: ["WicketHost"], resources: [.copy("Fixtures")]),
    ]
)
