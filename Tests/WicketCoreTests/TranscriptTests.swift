import Testing

@testable import WicketCore

struct TranscriptTests {
    /// Volatile results replace the tail; a final one joins the finalized text.
    @Test func volatileTailIsReplacedAndFinalSegmentsJoin() {
        var transcript = Transcript()
        transcript.apply("What", isFinal: false)
        transcript.apply("What's the", isFinal: false)
        #expect(transcript.text == "What's the")
        transcript.apply("What's the weather.", isFinal: true)
        #expect(transcript.text == "What's the weather.")
        transcript.apply(" in Ber", isFinal: false)
        #expect(transcript.text == "What's the weather. in Ber")
        transcript.apply(" in Berlin?", isFinal: true)
        #expect(transcript.text == "What's the weather. in Berlin?")
        #expect(transcript.volatile.isEmpty)
    }

    /// A spoken app name ends in a full stop, which would keep it from matching; a question mark is
    /// what marks a request, so it stays.
    @Test func searchTextDropsTheFullStopButKeepsAQuestionMark() {
        #expect(Transcript.searchText(" Safari. ") == "Safari")
        #expect(Transcript.searchText("Wie wird das Wetter morgen?") == "Wie wird das Wetter morgen?")
        #expect(Transcript.searchText("Hmm...") == "Hmm")
        #expect(Transcript.searchText("  ") == "")
    }
}
