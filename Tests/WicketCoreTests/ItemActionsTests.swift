import Foundation
import Testing

@testable import WicketCore

@Test func filesOpenRevealAndCopyTheirPath() {
    let url = URL(filePath: "/Users/me/Documents/Invoice.pdf")
    #expect(
        Item.Action.forFile(url) == [
            .open(url: url), .reveal(url: url), .copy(text: url.path, title: "Copy Path"),
        ])
    #expect(Item.Action.reveal(url: url).title == nil)
    #expect(Item.Action.reveal(url: url, title: "Reveal").title == "Reveal")
}

@Test func contentHasPublicInitialisers() {
    let detail = Detail(
        title: "Safari", markdown: "# Safari", metadata: [.init(label: "Version", value: "26.0")],
        actions: [.copy(text: "26.0")])
    #expect(Item.Action.detail(detail).title == "Safari")
    #expect(Detail(markdown: "x").metadata.isEmpty)
    #expect(RunResult.detail(detail) != RunResult.detail(Detail(markdown: "x")))
}
