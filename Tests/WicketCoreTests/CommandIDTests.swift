import Foundation
import Testing

@testable import WicketCore

// The canonical spelling of a `CommandID`, which logs and extension item ids use.

@Test(arguments: [
    ("builtin:run-agent", CommandID.builtin("run-agent")),
    ("builtin:settings", .builtin("settings")),
    ("ext:github/search", .extension("github", "search")),
    ("ext:github-prs/review-requests", .extension("github-prs", "review-requests")),
])
func commandIDsRoundTripTheirCanonicalSpelling(spelling: String, id: CommandID) {
    #expect(CommandID(spelling) == id)
    #expect(id.description == spelling)
    #expect(CommandID(id.description) == id)
}

@Test(arguments: [
    "", "settings", "builtin/settings", "builtin:", "builtin:Settings", "builtin:a:b", " builtin:quit",
    "builtin:quit ", "ext:github", "ext:github/", "ext:/search", "ext:git hub/search", "ext:a/b/c",
    "ext:a/b:c", "extension:a/b", "builtin:a/b",
])
func otherSpellingsAreNotCommandIDs(spelling: String) {
    #expect(CommandID(spelling) == nil)
}

@Test func itemIDsStillStartWithTheCanonicalSpelling() {
    #expect(Item.namespaced("pr-12", by: .extension("github", "search")) == "ext:github/search:pr-12")
    #expect(Item.namespaced("x", by: .builtin("run-agent")) == "builtin:run-agent:x")
}
