import Foundation

/// Whether typed text reads like a request to an AI (a question or an instruction) rather than a
/// search for something local. One cheap, pure rule, so a small on-device classifier can replace it.
///
/// A request is any of:
/// - text with a letter that ends with "?";
/// - two or more words starting with a question or instruction word, English or German ("how do
///   I", "erkläre mir");
/// - four or more plain words: words of letters only, so URLs, paths, file names ("AGENTS.md"),
///   numbers and maths don't count toward it ("100 usd in eur" has three).
public enum RequestText {
    static let minimumWords = 4

    static let starters: Set<String> = Set(
        [
            // English questions
            "what", "what's", "whats", "why", "how", "who", "whom", "whose", "when", "where", "which",
            "can", "could", "should", "would", "will", "is", "are", "was", "were", "do", "does", "did",
            // English instructions
            "explain", "summarize", "summarise", "translate", "write", "rewrite", "draft", "tell",
            "give", "compare", "define", "describe", "suggest", "help",
            // German questions
            "wie", "was", "warum", "wieso", "weshalb", "wer", "wann", "wo", "woher", "wohin", "welche",
            "welcher", "welches", "kann", "kannst", "können", "soll", "sollte", "ist", "sind", "gibt",
            // German instructions
            "erkläre", "erklär", "übersetze", "übersetz", "schreib", "schreibe", "fasse", "formuliere",
            "nenne", "vergleiche",
        ].map(Fold.fold))

    public static func readsLikeRequest(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard let first = words.first else { return false }
        if text.last(where: { !$0.isWhitespace }) == "?", text.contains(where: \.isLetter) { return true }
        if words.count >= 2, starters.contains(Fold.fold(String(first))) { return true }
        return words.count(where: isPlainWord) >= minimumWords
    }

    /// Letters only, allowing an inner apostrophe or hyphen ("don't", "e-mail") and trailing
    /// sentence punctuation.
    private static func isPlainWord(_ word: Substring) -> Bool {
        let core = word.drop { $0 == "\"" || $0 == "(" }.reversed().drop { ",.;:!?\")".contains($0) }
        guard let last = core.first, let first = core.last, first.isLetter, last.isLetter else {
            return false
        }
        return core.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
    }
}
