import AppKit
import Foundation

/// Snapshot of pasteboard items, including non-string flavors, for save/restore around paste.
public struct ClipboardSnapshot: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var representations: [String: Data]

        public init(representations: [String: Data]) {
            self.representations = representations
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    public static func capture(_ pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type.rawValue] = data
                }
            }
            return Item(representations: representations)
        }
        return ClipboardSnapshot(items: items)
    }

    /// Replaces the pasteboard with `text` and returns a snapshot that can restore the previous contents.
    @discardableResult
    public static func replaceString(_ text: String, on pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
        let snapshot = capture(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return snapshot
    }

    public func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let objects: [NSPasteboardItem] = items.map { item in
            let pbItem = NSPasteboardItem()
            for (rawType, data) in item.representations {
                pbItem.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return pbItem
        }
        pasteboard.writeObjects(objects)
    }
}
