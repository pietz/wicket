import Foundation

/// What the user has said so far while Wicket listens: the segments the recognizer finalized, then
/// the volatile tail it may still revise. Each volatile result replaces the tail; a final one
/// replaces it and joins the finalized text.
struct Transcript: Equatable, Sendable {
  private(set) var finalized = ""
  private(set) var volatile = ""

  private let separator: String
  init(locale: Locale = .current) {
    separator = ["zh", "ja"].contains(locale.language.languageCode?.identifier) ? "" : " "
  }

  mutating func apply(_ text: String, isFinal: Bool) {
    if isFinal {
      finalized = join(finalized, text)
      volatile = ""
    } else {
      volatile = text
    }
  }

  /// Segments keep native word boundaries for the selected transcription language.
  var text: String { join(finalized, volatile) }

  /// What a transcript puts into the search field: trimmed, without a trailing full stop, so
  /// "Safari." still matches the app. A question mark stays, since it tells Wicket the text is a
  /// request.
  static func searchText(_ spoken: String) -> String {
    var text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = text.last, last == "." || last == "。" {
      text.removeLast()
    }
    return text
  }

  private func join(_ head: String, _ tail: String) -> String {
    let head = head.trimmingCharacters(in: .whitespaces)
    let tail = tail.trimmingCharacters(in: .whitespaces)
    if head.isEmpty { return tail }
    if tail.isEmpty { return head }
    return head + separator + tail
  }
}
