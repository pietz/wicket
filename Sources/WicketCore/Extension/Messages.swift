import Foundation

/// What Wicket writes to an extension's stdin: one JSON object, then end of file.
public struct Request: Sendable, Hashable, Encodable {
    public var command: String
    public var text: String
    public var args: [String: JSONValue]?

    public init(command: String, text: String, args: [String: JSONValue]? = nil) {
        self.command = command
        self.text = text
        self.args = args
    }

    /// The request as one line, newline included.
    public var line: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding plain values can't fail.
        return try! encoder.encode(self) + Data("\n".utf8)
    }
}

/// An error an extension answered with; `message` is shown to the user as is.
public struct ExtensionError: Error, Sendable, Hashable, Decodable, CustomStringConvertible {
    public var message: String
    /// Details for the diagnostics, never shown in the view.
    public var data: JSONValue?

    public init(from decoder: any Decoder) throws {
        let object = try decoder.object(["message", "data"])
        message = try object.nonEmpty("message")
        data = try object.optional("data")
    }

    public var description: String { message }
}

/// What an extension wrote to stdout: one result, or `{"error": {...}}`.
public enum Response {
    /// Decodes `data` strictly, with the rules of the command it answers.
    public static func decode(_ data: Data, context: WireContext) throws -> Result<RunResult, ExtensionError>
    {
        let decoder = JSONDecoder()
        decoder.userInfo[WireContext.key] = context
        return try decoder.decode(Body.self, from: data).outcome
    }

    private struct Body: Decodable {
        let outcome: Result<RunResult, ExtensionError>

        init(from decoder: any Decoder) throws {
            let object = try decoder.container(keyedBy: AnyKey.self)
            if object.allKeys.map(\.stringValue) == ["error"] {
                outcome = .failure(try object.required("error"))
            } else {
                outcome = .success(try RunResult(from: decoder))
            }
        }
    }
}
