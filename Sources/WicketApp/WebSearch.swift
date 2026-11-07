import AppKit
import WicketCore

/// Search the Web: opens the user's search address (settings.json `webSearch.url`) for the
/// submitted text and closes the palette.
@MainActor
final class WebSearchRunner: CommandRunner {
    /// The applied search address, read on each run; nil before settings are applied.
    private let template: () -> String?

    init(template: @escaping () -> String?) {
        self.template = template
    }

    func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error> {
        // Settings only accept an address that builds a URL.
        let template = template() ?? WebQuery.defaultTemplate
        if let url = WebQuery.searchURL(template: template, query: invocation.text) {
            NSWorkspace.shared.open(url)
        }
        return AsyncThrowingStream {
            $0.yield(.close(message: nil))
            $0.finish()
        }
    }
}

/// One answer row, "Open apple.com", when the query plainly is a web address (`WebQuery.link`).
/// Its id is the web search feature's, so turning that off removes it too.
struct LinkSource: ResultSource {
    let id = Feature.webSearch.rawValue

    func instant(_ query: Query) -> [Item] {
        WebQuery.link(query.text).map { [WebQuery.linkItem($0)] } ?? []
    }
}
