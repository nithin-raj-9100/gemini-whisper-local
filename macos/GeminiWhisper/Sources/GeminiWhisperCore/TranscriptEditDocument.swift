import Foundation

/// Immutable candidate snapshot. IDs are scoped to this revision, not guessed offsets.
public struct TranscriptEditDocument: Sendable {
    public let revision: String
    public let spans: [String]

    public init(_ text: String, revision: String = UUID().uuidString) {
        self.revision = revision
        var result: [String] = []
        var span = ""
        for character in text {
            span.append(character)
            if span.count >= 200, character.isWhitespace {
                result.append(span)
                span = ""
            }
        }
        if !span.isEmpty { result.append(span) }
        result.append("") // Explicit append position; no implicit spaces during assembly.
        spans = result
    }

    public func applying(_ data: Data) throws -> String {
        struct Patch: Decodable {
            struct Edit: Decodable { let id: String; let text: String }
            let revision: String
            let edits: [Edit]
        }
        let patch = try JSONDecoder().decode(Patch.self, from: data)
        guard patch.revision == revision else { throw TranscriptionError("Stale edit revision.") }
        var seen = Set<Int>()
        var output = spans
        for edit in patch.edits {
            guard edit.id.hasPrefix("s"), let index = Int(edit.id.dropFirst()),
                  edit.id == "s\(index)", output.indices.contains(index), seen.insert(index).inserted else {
                throw TranscriptionError("Invalid or duplicate edit span.")
            }
            output[index] = edit.text
        }
        let text = output.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError("Edits removed the entire transcript.") }
        return text
    }
}
