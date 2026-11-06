import Foundation

/// A JSON-RPC request id: a number or a string, echoed back unchanged.
public enum RequestID: Sendable, Hashable, Codable, CustomStringConvertible {
    case number(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Int.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else {
            throw decoder.invalid("id must be an integer or a string")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        }
    }

    public var description: String {
        switch self {
        case .number(let number): String(number)
        case .string(let string): "\"\(string)\""
        }
    }

    public init?(_ value: JSONValue?) {
        switch value {
        case .integer(let number): self = .number(number)
        case .string(let string): self = .string(string)
        default: return nil
        }
    }
}

public struct RunParams: Sendable, Hashable, Codable {
    public var command: String
    public var text: String
    public var revision: Int
    public var args: [String: JSONValue]?

    public init(command: String, text: String, revision: Int, args: [String: JSONValue]? = nil) {
        self.command = command
        self.text = text
        self.revision = revision
        self.args = args
    }

    public init(from decoder: any Decoder) throws {
        let object = try decoder.object(["command", "text", "revision", "args"])
        command = try object.slug("command")
        text = try object.required("text")
        revision = try object.required("revision")
        args = try object.optional("args")
    }
}

/// What Wicket writes to an extension's stdin.
public enum HostMessage: Sendable, Hashable, Codable {
    case run(id: RequestID, RunParams)
    case cancel(id: RequestID)

    private enum Keys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    public func encode(to encoder: any Encoder) throws {
        var object = encoder.container(keyedBy: Keys.self)
        try object.encode("2.0", forKey: .jsonrpc)
        switch self {
        case .run(let id, let params):
            try object.encode(id, forKey: .id)
            try object.encode("run", forKey: .method)
            try object.encode(params, forKey: .params)
        case .cancel(let id):
            try object.encode("cancel", forKey: .method)
            try object.encode(["id": id], forKey: .params)
        }
    }

    /// Strict, for fixtures: the messages a test sends must be ones Wicket could send.
    public init(from decoder: any Decoder) throws {
        let object = try decoder.object(["jsonrpc", "id", "method", "params"])
        try object.requireJSONRPC()
        switch try object.required("method", as: String.self) {
        case "run":
            self = .run(id: try object.required("id"), try object.required("params"))
        case "cancel":
            if object.has("id") { throw object.invalid("id", "a notification has no id") }
            self = .cancel(id: try object.object("params", ["id"]).required("id"))
        case let method:
            throw object.invalid("method", "\"\(method)\" is not a Wicket method; use run or cancel")
        }
    }

    /// One line of the protocol, newline included.
    public var line: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // Encoding plain values can't fail.
        return try! encoder.encode(self) + Data("\n".utf8)
    }
}

/// An error an extension answered with; `message` is shown to the user as is.
public struct ExtensionError: Error, Sendable, Hashable, Decodable, CustomStringConvertible {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(from decoder: any Decoder) throws {
        let object = try decoder.object(["code", "message", "data"])
        code = try object.required("code")
        message = try object.nonEmpty("message")
        data = try object.optional("data")
    }

    public var description: String { message }
}

/// A line an extension wrote to stdout, decoded strictly.
public struct Response: Sendable, Hashable, Decodable {
    /// Nil only for an error about a line the extension couldn't parse.
    public var id: RequestID?
    public var outcome: Result<RunResult, ExtensionError>

    public init(from decoder: any Decoder) throws {
        let object = try decoder.object(["jsonrpc", "id", "result", "error"])
        try object.requireJSONRPC()
        guard object.has("id") else { throw decoder.invalid("missing required field \"id\"") }
        id = try object.decodeNil(forKey: AnyKey("id")) ? nil : object.required("id")
        switch (object.has("result"), object.has("error")) {
        case (true, false):
            if id == nil { throw object.invalid("id", "must not be null in a result") }
            outcome = .success(try object.required("result"))
        case (false, true):
            outcome = .failure(try object.required("error"))
        default:
            throw decoder.invalid("a response has exactly one of result and error")
        }
    }

    /// Decodes `line` with the rules of the command it answers.
    public static func decode(_ line: Data, context: WireContext) throws -> Response {
        let decoder = JSONDecoder()
        decoder.userInfo[WireContext.key] = context
        return try decoder.decode(Response.self, from: line)
    }
}

extension KeyedDecodingContainer where Key == AnyKey {
    fileprivate func requireJSONRPC() throws {
        guard try required("jsonrpc", as: String.self) == "2.0" else {
            throw invalid("jsonrpc", "must be \"2.0\"")
        }
    }
}
