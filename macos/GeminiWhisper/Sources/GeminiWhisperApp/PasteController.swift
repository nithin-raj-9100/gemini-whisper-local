import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GeminiWhisperCore

/// In-process paste: NSPasteboard + synthesized Cmd+V from this process (not osascript).
@MainActor
enum PasteController {
    /// kVK_ANSI_V
    private static let keyCodeV: CGKeyCode = 0x09
    /// kVK_Command
    private static let keyCodeCommand: CGKeyCode = 0x37
    /// kVK_LeftArrow
    private static let keyCodeLeftArrow: CGKeyCode = 0x7B
    /// Floor before Cmd+V: the readback below proves *our* view of the pasteboard,
    /// but the target process still has to observe the change. Kept small and
    /// polled up to the cap instead of always paying the worst case.
    private static let pasteboardSettleFloorNanoseconds: UInt64 = 8_000_000
    private static let pasteboardSettleCapNanoseconds: UInt64 = 50_000_000
    private static let pasteboardPollNanoseconds: UInt64 = 2_000_000
    private static let pasteConsumeNanoseconds: UInt64 = 400_000_000

    static var executableURL: URL {
        Bundle.main.executableURL ?? Bundle.main.bundleURL
    }

    static var bundleURL: URL {
        Bundle.main.bundleURL
    }

    static var runningIdentity: String {
        executableURL.path
    }

    static var isAppBundle: Bool {
        bundleURL.pathExtension == "app"
            || bundleURL.path.contains(".app/")
    }

    static func frontmostApplication() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    static func hasPasteAutomationPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Short enough for a notification banner. Full executable path is in Settings and the log file.
    static func pastePermissionMessage() -> String {
        if isAppBundle {
            return "Re-add THIS GeminiWhisper.app in Accessibility (toggle can stay ON after a rebuild), then quit and reopen."
        }
        return "Quit this debug binary, open macos/GeminiWhisper.app, and grant that .app Accessibility."
    }

    @discardableResult
    static func promptAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        AppLog.line("Paste Accessibility prompt; trusted=\(trusted) executable=\(runningIdentity)")
        return trusted
    }

    /// Returns `true` when text was pasted; `false` when it was copied because focus moved.
    @discardableResult
    static func pasteIntoFocusedApplication(_ text: String, expectedApplication: String?) async throws -> Bool {
        let trustedAtStart = AXIsProcessTrusted()
        AppLog.line(
            "Paste begin trusted=\(trustedAtStart) bundle=\(bundleURL.path) " +
                "executable=\(runningIdentity) chars=\(text.count) frontmost=\(frontmostApplication() ?? "nil") " +
                "expected=\(expectedApplication ?? "nil")"
        )
        if !trustedAtStart {
            _ = promptAccessibilityIfNeeded()
        }

        let currentApplication = frontmostApplication()
        if let currentApplication, currentApplication == "GeminiWhisper" || currentApplication == "GeminiWhisperApp" {
            try copyText(text)
            AppLog.line("Paste skipped; frontmost application is GeminiWhisper. Copied to clipboard.")
            return false
        }

        if let expectedApplication, let currentApplication, currentApplication != expectedApplication {
            AppLog.line("Focus moved \(expectedApplication) -> \(currentApplication); pasting into currently focused \(currentApplication)")
        }

        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot.replaceString(text, on: pasteboard)
        guard pasteboard.string(forType: .string) == text else {
            snapshot.restore(to: pasteboard)
            AppLog.line("Paste clipboard write failed")
            throw PasteError.failed("Could not write the transcript to the clipboard.")
        }
        do {
            let settledNs = try await awaitPasteboardSettled(text, on: pasteboard)
            AppLog.line("Paste clipboard written (\(text.count) chars); settled in \(settledNs / 1_000_000)ms")
            try postCommandV()
            // If Accessibility is still false the HID events were likely
            // dropped: keep the transcript on the clipboard so Cmd+V works
            // even when posted events vanish. AXIsProcessTrusted() can also
            // stay false after a rebuild while Settings still shows ON
            // (stale TCC CDHash).
            let trustedAfterPost = AXIsProcessTrusted()
            if !trustedAfterPost {
                AppLog.line("Paste events posted but trusted=false; leaving transcript on clipboard")
                throw PasteError.needsAccessibility(pastePermissionMessage())
            }

            // Keystrokes are posted: return now so stop-to-paste isn't gated
            // on the consume window. The user's clipboard is restored in the
            // background once the target has consumed the paste.
            AppLog.line("Paste Cmd+V posted to cghidEventTap; clipboard restore scheduled")
            Task {
                try? await Task.sleep(nanoseconds: pasteConsumeNanoseconds)
                snapshot.restore(to: pasteboard)
            }
            return true
        } catch let error as PasteError {
            if case .needsAccessibility(_) = error {
                throw error
            }
            snapshot.restore(to: pasteboard)
            AppLog.line("Paste failed: \(error.localizedDescription)")
            throw error
        } catch {
            snapshot.restore(to: pasteboard)
            AppLog.line("Paste failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Reselect the last `count` characters this app inserted and paste `text`
    /// over them. Arrow keys move by grapheme cluster, which is exactly what
    /// String.count measures, so the selection matches what was inserted.
    /// Returns false when the target refused the selection keystrokes.
    @discardableResult
    static func replaceLastCharacters(count: Int, with text: String, expectedApplication: String?) async throws -> Bool {
        guard count > 0 else { return false }
        guard AXIsProcessTrusted() else {
            throw PasteError.needsAccessibility(pastePermissionMessage())
        }
        let currentApplication = frontmostApplication()
        if let expectedApplication, currentApplication != expectedApplication {
            AppLog.line("Repair skipped; focus moved \(expectedApplication) -> \(currentApplication ?? "nil")")
            return false
        }

        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot.replaceString(text, on: pasteboard)
        guard pasteboard.string(forType: .string) == text else {
            snapshot.restore(to: pasteboard)
            throw PasteError.failed("Could not write the polished transcript to the clipboard.")
        }
        do {
            _ = try await awaitPasteboardSettled(text, on: pasteboard)
            try postShiftLeftArrow(times: count)
            try postCommandV()
            AppLog.line("Repair replaced \(count) characters with \(text.count); clipboard restore scheduled")
            Task {
                try? await Task.sleep(nanoseconds: pasteConsumeNanoseconds)
                snapshot.restore(to: pasteboard)
            }
            return true
        } catch {
            snapshot.restore(to: pasteboard)
            AppLog.line("Repair failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Sleep the floor, then poll until the write reads back, up to the cap.
    /// Returns the nanoseconds actually waited.
    private static func awaitPasteboardSettled(_ text: String, on pasteboard: NSPasteboard) async throws -> UInt64 {
        try await Task.sleep(nanoseconds: pasteboardSettleFloorNanoseconds)
        var waited = pasteboardSettleFloorNanoseconds
        while waited < pasteboardSettleCapNanoseconds {
            if pasteboard.string(forType: .string) == text { return waited }
            try await Task.sleep(nanoseconds: pasteboardPollNanoseconds)
            waited += pasteboardPollNanoseconds
        }
        return waited
    }

    private static func postShiftLeftArrow(times: Int) throws {
        guard let source = CGEventSource(stateID: .hidSystemState)
            ?? CGEventSource(stateID: .combinedSessionState)
        else {
            throw eventFailure("Could not create a keyboard event source for the repair selection.")
        }
        source.localEventsSuppressionInterval = 0
        for _ in 0..<times {
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeLeftArrow, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeLeftArrow, keyDown: false)
            else {
                throw eventFailure("Could not create the repair selection keystrokes.")
            }
            down.flags = .maskShift
            up.flags = .maskShift
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    static func copyText(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw PasteError.failed("Could not copy the transcript.")
        }
    }

    private static func postCommandV() throws {
        let source: CGEventSource
        if let hid = CGEventSource(stateID: .hidSystemState) {
            source = hid
            AppLog.line("Paste CGEventSource hidSystemState created")
        } else if let combined = CGEventSource(stateID: .combinedSessionState) {
            source = combined
            AppLog.line("Paste CGEventSource hidSystemState nil; using combinedSessionState")
        } else {
            AppLog.line("Paste CGEventSource creation failed (hidSystemState and combinedSessionState)")
            throw eventFailure("Could not create a keyboard event source for Cmd+V.")
        }
        source.localEventsSuppressionInterval = 0

        guard
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCommand, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCommand, keyDown: false)
        else {
            AppLog.line("Paste CGEvent keyboard events not created")
            throw eventFailure("Could not create Cmd+V keyboard events.")
        }
        AppLog.line("Paste CGEvent command/V keyDown+keyUp created")

        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.flags = []

        commandDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
        AppLog.line("Paste posted commandDown, vDown, vUp, commandUp via cghidEventTap")
    }

    private static func eventFailure(_ detail: String) -> PasteError {
        if AXIsProcessTrusted() {
            return .failed("\(detail) Accessibility is granted; Cmd+V was not posted.")
        }
        return .needsAccessibility(pastePermissionMessage())
    }

    enum PasteError: LocalizedError {
        case failed(String)
        case needsAccessibility(String)
        var errorDescription: String? {
            switch self {
            case .failed(let message), .needsAccessibility(let message): return message
            }
        }
    }
}
