import WicketCore

/// Wicket's own commands, such as Quit Wicket. Item ids are "commands:" plus the command id.
@MainActor
final class CommandsSource: ResultSource {
    struct Command {
        let id: String
        let title: String
        let symbol: String
        let run: @MainActor () -> Void
    }

    let id = "commands"
    private let commands: [String: Command]
    private let index: SearchIndex

    init(_ commands: [Command]) {
        self.commands = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
        index = SearchIndex(
            commands.map { command in
                let item = Item(
                    id: "commands:" + command.id, title: command.title, icon: .symbol(name: command.symbol),
                    accessory: "Command", actions: [.command(id: command.id)])
                return (item, [])
            })
    }

    func instant(_ query: Query) -> [Item] {
        index.search(query.text)
    }

    func run(_ id: String) {
        guard let command = commands[id] else {
            Perf.logger.error("unknown command \(id, privacy: .public)")
            return
        }
        command.run()
    }
}
