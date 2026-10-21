import Foundation

/// One finished, failed, or abandoned dictation. Kept in memory only, so a
/// transcript that never reached its target can still be copied, pasted, or
/// transcribed again from its audio.
public struct TranscriptHistoryEntry: Identifiable, Sendable, Equatable {
    public enum Outcome: String, Sendable {
        case inserted
        case copied
        /// Cmd+V was posted but the target's text did not change; the transcript was left on the clipboard.
        case pasteUnconfirmed = "paste_unconfirmed"
        case failed
        case cancelled
        case interrupted
        case empty
    }

    public let id: UUID
    public let date: Date
    public var text: String
    public var targetName: String?
    public var outcome: Outcome
    public var detail: String
    public var audio: RecordedAudio?

    public init(id: UUID = UUID(), date: Date = Date(), text: String, targetName: String?,
                outcome: Outcome, detail: String = "", audio: RecordedAudio? = nil) {
        self.id = id
        self.date = date
        self.text = text
        self.targetName = targetName
        self.outcome = outcome
        self.detail = detail
        self.audio = audio
    }
}

/// Newest-first ring buffer. Audio is large (about 2 MB a minute), so only the
/// most recent few entries keep it.
public struct TranscriptHistory: Sendable, Equatable {
    public private(set) var entries: [TranscriptHistoryEntry] = []
    public let capacity: Int
    public let audioCapacity: Int

    public init(capacity: Int = 20, audioCapacity: Int = 3) {
        self.capacity = max(1, capacity)
        self.audioCapacity = max(0, audioCapacity)
    }

    @discardableResult
    public mutating func record(_ entry: TranscriptHistoryEntry) -> UUID {
        entries.insert(entry, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        var kept = 0
        for index in entries.indices where entries[index].audio != nil {
            kept += 1
            if kept > audioCapacity { entries[index].audio = nil }
        }
        return entry.id
    }

    public mutating func update(_ id: UUID, outcome: TranscriptHistoryEntry.Outcome, detail: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].outcome = outcome
        entries[index].detail = detail
    }

    /// Most recent non-empty transcript, whatever happened to it.
    public var lastText: String? {
        entries.first { !$0.text.isEmpty }?.text
    }

    /// Most recent entry whose audio is still kept.
    public var lastRecording: TranscriptHistoryEntry? {
        entries.first { $0.audio?.isEmpty == false }
    }

    public func entry(_ id: UUID) -> TranscriptHistoryEntry? {
        entries.first { $0.id == id }
    }
}
