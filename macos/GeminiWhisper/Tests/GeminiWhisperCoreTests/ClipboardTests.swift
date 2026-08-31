import AppKit
@testable import GeminiWhisperCore
import Testing

@Suite("ClipboardSnapshot")
@MainActor
struct ClipboardTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func replaceStringThenRestoreRecoversPriorString() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        #expect(pasteboard.setString("prior clipboard", forType: .string))

        let snapshot = ClipboardSnapshot.replaceString("dictated text", on: pasteboard)
        #expect(pasteboard.string(forType: .string) == "dictated text")

        snapshot.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "prior clipboard")
    }

    @Test func restoreRecoversNonStringFlavor() {
        let pasteboard = NSPasteboard.withUniqueName()
        let custom = NSPasteboard.PasteboardType("com.nithin.gemini-whisper.test.blob")
        let blob = Data([0xDE, 0xAD, 0xBE, 0xEF])
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(blob, forType: custom)
        #expect(pasteboard.writeObjects([item]))

        let snapshot = ClipboardSnapshot.replaceString("replaced", on: pasteboard)
        #expect(pasteboard.string(forType: .string) == "replaced")
        #expect(pasteboard.data(forType: custom) == nil)

        snapshot.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "hello")
        #expect(pasteboard.data(forType: custom) == blob)
    }

    @Test func restoreClearsPasteboardWhenSnapshotWasEmpty() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        let snapshot = ClipboardSnapshot.capture(pasteboard)
        #expect(pasteboard.setString("temporary", forType: .string))

        snapshot.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
    }
}
