import Foundation
import Testing

@testable import WicketCore

@Test func revealRoundTripsThroughACommand() {
    let url = URL(filePath: "/Applications/Safari.app")
    #expect(Item.Action.reveal(url).revealedURL == url)
    #expect(Item.Action.command(id: "quit").revealedURL == nil)
    #expect(Item.Action.open(url: url).revealedURL == nil)
}

@Test func filesOpenRevealAndCopyTheirPath() {
    let url = URL(filePath: "/Users/me/Documents/Invoice.pdf")
    #expect(
        Item.Action.forFile(url) == [
            .open(url: url), .reveal(url), .copy(text: url.path, title: "Copy Path"),
        ])
}
