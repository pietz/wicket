import Foundation

/// A searchable string, prepared once at index time so a keystroke does no string work.
struct SearchKey: Sendable, Hashable {
  /// Folded (case, diacritic and width insensitive) scalars.
  let scalars: [UInt32]
  /// Per scalar: 2 at the start of the string, 1 at the start of a word, 0 otherwise.
  let boundary: [UInt8]
  /// `scalars` without whitespace, matching how queries are folded, for exact and prefix checks.
  let compact: [UInt32]

  init(_ text: String) {
    var scalars: [UInt32] = []
    var boundary: [UInt8] = []
    scalars.reserveCapacity(text.unicodeScalars.count)
    boundary.reserveCapacity(text.unicodeScalars.count)
    let characters = Array(text)
    var previous: Character?
    for (index, character) in characters.enumerated() {
      let next = index + 1 < characters.count ? characters[index + 1] : nil
      let flag = Self.boundaryFlag(
        character, previous: previous, next: next, isFirst: scalars.isEmpty)
      for (offset, scalar) in Fold.fold(String(character)).unicodeScalars.enumerated() {
        scalars.append(scalar.value)
        boundary.append(offset == 0 ? flag : 0)
      }
      previous = character
    }
    self.scalars = scalars
    self.boundary = boundary
    self.compact = scalars.filter { !(Unicode.Scalar($0)?.properties.isWhitespace ?? false) }
  }

  private static func boundaryFlag(
    _ character: Character, previous: Character?, next: Character?, isFirst: Bool
  ) -> UInt8 {
    if isFirst { return 2 }
    guard let previous, !isSeparator(character) else { return 0 }
    if isSeparator(previous) { return 1 }
    // camelCase: "OrbStack" -> S starts a word.
    if character.isUppercase && previous.isLowercase { return 1 }
    // Acronym run ending: "BBEdit" -> E starts a word.
    if character.isUppercase && previous.isUppercase, let next, next.isLowercase { return 1 }
    // Digits and letters: "1Password" -> P, "Office365" -> 3.
    if character.isLetter && previous.isNumber { return 1 }
    if character.isNumber && previous.isLetter { return 1 }
    return 0
  }

  static func isSeparator(_ character: Character) -> Bool {
    character.isWhitespace || "-_./()[]&+:,".contains(character)
  }
}

enum Fold {
  /// The one text fold used for both index and query.
  static func fold(_ text: String) -> String {
    if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
    return text.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
  }

  /// Query scalars with whitespace removed: "vs code" and "vscode" behave alike.
  static func query(_ text: String) -> [UInt32] {
    fold(text).unicodeScalars.filter { !$0.properties.isWhitespace }.map(\.value)
  }

  /// The query's words, each folded like `query`.
  static func words(_ text: String) -> [[UInt32]] {
    text.split(whereSeparator: \.isWhitespace).map { query(String($0)) }
  }
}

/// Subsequence fuzzy matcher. Finds the best-scoring alignment of the query over a key.
///
/// Every query scalar must appear in order. An alignment earns points for landing on the start of
/// the string or a word, and for runs of consecutive matches; each jump costs a flat penalty.
/// Runs in O(query × key) with two rolling rows.
enum FuzzyMatcher {
  enum Weight {
    static let match = 1
    static let stringStart = 12
    static let wordStart = 8
    static let consecutive = 6
    static let gap = -2
    static let prefix = 10
    static let exact = 100
  }

  /// The whole query in order, so "vs code" scores like "vscode"; failing that, the sum of every
  /// word scored on its own, in any order, the way Spotlight matches file names: "invoice q3" finds
  /// "Q3 Invoice.pdf". Nil when a word misses. `query` and `words` are `Fold.query` and `Fold.words`
  /// of the same input.
  static func score(_ query: [UInt32], words: [[UInt32]], _ key: SearchKey) -> Int? {
    if let whole = score(query, key) { return whole }
    guard words.count > 1 else { return nil }
    var total = 0
    for word in words {
      guard let score = score(word, key) else { return nil }
      total += score
    }
    return total
  }

  /// Returns nil when the query is not a subsequence of the key or the match is too weak.
  static func score(_ query: [UInt32], _ key: SearchKey) -> Int? {
    let n = query.count
    let m = key.scalars.count
    guard n > 0, n <= m else { return nil }

    let unset = Int.min / 2
    // previous[j]: best score with query[i-1] matched exactly at key[j].
    var previous = [Int](repeating: unset, count: m)
    var current = [Int](repeating: unset, count: m)

    for i in 0..<n {
      let q = query[i]
      // Best previous-row score at any k < j - 1 (a jump to j).
      var bestBeforeGap = unset
      for j in 0..<m {
        if i > 0, j >= 2 { bestBeforeGap = max(bestBeforeGap, previous[j - 2]) }
        guard key.scalars[j] == q, j >= i else {
          current[j] = unset
          continue
        }
        let bonus: Int
        switch key.boundary[j] {
        case 2: bonus = Weight.stringStart
        case 1: bonus = Weight.wordStart
        default: bonus = 0
        }
        let here = Weight.match + bonus
        if i == 0 {
          current[j] = here
        } else {
          let adjacent =
            j >= 1 && previous[j - 1] > unset
            ? previous[j - 1] + Weight.consecutive : unset
          let jumped = bestBeforeGap > unset ? bestBeforeGap + Weight.gap : unset
          let best = max(adjacent, jumped)
          current[j] = best > unset ? best + here : unset
        }
      }
      swap(&previous, &current)
    }

    guard var best = previous.max(), best > unset else { return nil }
    if key.compact.starts(with: query) {
      best += n == key.compact.count ? Weight.exact : Weight.prefix
    }
    // Reject scattered mid-word hits: on average each scalar must earn more than a gap costs.
    guard best >= 2 * n else { return nil }
    return best
  }
}
