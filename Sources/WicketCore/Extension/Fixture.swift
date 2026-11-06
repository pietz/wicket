import Foundation

/// A `session.jsonl` test: messages to send and the responses to expect, one JSON object per line.
public struct Fixture: Sendable {
    public enum Step: Sendable {
        case send(HostMessage)
        /// The response with `id` must match `pattern` (see `JSONValue.mismatch`).
        case expect(id: RequestID, pattern: JSONValue)
    }

    /// Each step with its 1-based line number.
    public var steps: [(line: Int, step: Step)]

    /// Parses fixture text; blank lines are skipped. Errors name the line.
    public init(_ text: String) throws(FixtureError) {
        steps = []
        for (index, text) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = index + 1
            guard !text.allSatisfy(\.isWhitespace) else { continue }
            let value: JSONValue
            do {
                value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            } catch {
                throw FixtureError(line: line, message: "not valid JSON")
            }
            guard case .object(let object) = value, object.count == 1, let (kind, body) = object.first,
                kind == "send" || kind == "expect"
            else {
                throw FixtureError(
                    line: line, message: "must be {\"send\": message} or {\"expect\": response}")
            }
            if kind == "send" {
                do {
                    let message = try JSONDecoder().decode(HostMessage.self, from: Data(body.json.utf8))
                    steps.append((line, .send(message)))
                } catch let error as DecodingError {
                    throw FixtureError(line: line, message: "send: \(error.summary)")
                } catch {
                    throw FixtureError(line: line, message: "send: \(error.localizedDescription)")
                }
            } else {
                guard let id = RequestID(body["id"]) else {
                    throw FixtureError(line: line, message: "expect needs the id of the response it matches")
                }
                steps.append((line, .expect(id: id, pattern: body)))
            }
        }
    }
}

public struct FixtureError: Error, Sendable, Equatable, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}
