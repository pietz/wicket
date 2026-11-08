import Foundation
import WicketCore
import os

// The palette command that accepts a declared extension secret and stores it in the Keychain.

extension CommandID {
    /// Stores the submitted text as an extension's secret (args: `id`, `name`). Hidden: reached by
    /// the Set action of an extension's page or of a run that needed the secret.
    public static let setSecret = CommandID.builtin("set-secret")
}

/// Sets an extension's secret from the palette: its frame waits for the value, and Return stores it
/// in the Keychain (the same item `wicket secret set` writes), which the next run reads, and closes
/// with "Stored NAME". Only a secret the extension declares is
/// stored. The value is never logged, shown or kept anywhere else.
@MainActor
public final class SecretsRunner: CommandRunner {
    private let extensions: Extensions
    private let store: @Sendable (_ value: String, _ name: String, _ id: String) throws -> Void

    private static let logger = Logger(subsystem: "app.wicket", category: "secrets")

    /// `store` writes a value (the Keychain by default; tests pass their own).
    public init(
        extensions: Extensions,
        store: @escaping @Sendable (_ value: String, _ name: String, _ id: String) throws -> Void = {
            try Keychain.setSecret($0, name: $1, extension: $2)
        }
    ) {
        self.extensions = extensions
        self.store = store
    }

    /// The action that asks for the extension `id`'s secret `name`.
    public static func action(extension id: String, name: String) -> Item.Action {
        .run(command: .setSecret, args: ["id": .string(id), "name": .string(name)], title: "Set \(name)…")
    }

    public func run(_ invocation: Invocation) -> AsyncThrowingStream<RunResult, any Error> {
        AsyncThrowingStream { continuation in
            do {
                continuation.yield(try set(invocation))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private func set(_ invocation: Invocation) throws -> RunResult {
        guard case .string(let id)? = invocation.args?["id"],
            case .string(let name)? = invocation.args?["name"]
        else { throw UserError("Open the extension in Extensions to set its secrets.") }
        let found = extensions.discovered.first { $0.id == id }
        let declared = [found?.approved, found?.sealed].compactMap { $0 }.flatMap(\.manifest.secrets)
        guard declared.contains(where: { $0.name == name }) else {
            throw UserError("The extension \(id) doesn't declare the secret \(name).")
        }
        // A pasted value often brings a line break along.
        let value = invocation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw UserError("Paste the value of \(name), then press Return.") }
        try store(value, name, id)
        Self.logger.notice("secret stored")
        return .close(message: "Stored \(name).")
    }
}
