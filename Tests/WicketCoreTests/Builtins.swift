import WicketCore

// Wicket's built-ins as the app's table registers them (`AppRuntime.live()`), for the registries
// these tests build. Core has no built-ins of its own: the app composes them.

extension CommandID {
    static let settings = CommandID.builtin("settings")
    static let quit = CommandID.builtin("quit")
    static let runAgent = CommandID.builtin("run-agent")
}

extension RegisteredCommand {
    static let settings = RegisteredCommand(
        id: .settings, title: "Wicket Settings", icon: .symbol(name: "gearshape"), input: .none)
    static let quit = RegisteredCommand(
        id: .quit, title: "Quit Wicket", icon: .symbol(name: "power"), input: .none)
    static let runAgent = RegisteredCommand(
        id: .runAgent, title: "Run Agent", icon: .symbol(name: "sparkles"), keyword: "ai", isListed: false,
        input: .submitText, placeholder: "Ask a question", isFallback: true, feature: .ai,
        usesContext: true)
}

/// The built-ins in the app's order.
let builtins: [RegisteredCommand] = [.settings, .quit, .runAgent]

/// The action Run Agent's fallback row has for `prompt`.
func asking(_ prompt: String) -> Item.Action {
    .run(command: .runAgent, text: prompt, title: "Run Agent")
}
