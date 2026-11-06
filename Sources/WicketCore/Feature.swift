import Foundation

/// A built-in result source the user can turn off (settings.json `features`, Settings ▸ Features).
/// Its raw value is its key in the file and its source's id. A feature that is off does no work at
/// all: its source leaves the root search, and the app stops whatever feeds it (the app scan, the
/// exchange rates). Commands are not a feature: Wicket Settings lives there, so turning them off
/// could lock the user out of the window that turns them back on.
public enum Feature: String, CaseIterable, Sendable {
    case apps, files, calculator
    case askAI = "ask-ai"

    public var title: String {
        switch self {
        case .apps: "Applications"
        case .files: "Files"
        case .calculator: "Calculator"
        case .askAI: "Ask AI"
        }
    }

    /// One line for the Features pane.
    public var summary: String {
        switch self {
        case .apps: "Find and open apps by name."
        case .files: "Find files and folders with Spotlight."
        case .calculator: "Math, units and currencies as you type."
        case .askAI: "Ask your agent anything, with the ai prefix or the last row."
        }
    }

    /// The built-in commands that exist only with this feature: off, they leave the registry, so
    /// their hotkeys and aliases stay in settings.json but do nothing.
    public var commands: [BuiltinCommand] {
        self == .askAI ? [.askAI] : []
    }

    /// `sources` without those of the features `settings` turns off; sources that aren't a
    /// feature's (commands, extensions) always stay.
    @MainActor
    public static func enabled(_ sources: [any ResultSource], in settings: Settings) -> [any ResultSource] {
        sources.filter { source in Feature(rawValue: source.id).map(settings.isEnabled) ?? true }
    }
}
