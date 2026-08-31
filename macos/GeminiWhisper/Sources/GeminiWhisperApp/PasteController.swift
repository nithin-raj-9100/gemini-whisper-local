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
    private static let pasteboardSettleNanoseconds: UInt64 = 50_000_000
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
        if let expectedApplication, let currentApplication, currentApplication != expectedApplication {
            try copyText(text)
            AppLog.line("Paste skipped; focus moved \(expectedApplication) -> \(currentApplication)")
            UserNotify.show(
                "Focus moved from \(expectedApplication) to \(currentApplication). The transcript was copied instead of pasted."
            )
            return false
        }

        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot.replaceString(text, on: pasteboard)
        guard pasteboard.string(forType: .string) == text else {
            snapshot.restore(to: pasteboard)
            AppLog.line("Paste clipboard write failed")
            throw PasteError.failed("Could not write the transcript to the clipboard.")
        }
        AppLog.line("Paste clipboard written (\(text.count) chars); settling 50ms")

        do {
            try await Task.sleep(nanoseconds: pasteboardSettleNanoseconds)
            try postCommandV()
            AppLog.line("Paste Cmd+V posted to cghidEventTap; waiting 400ms before clipboard restore")
            try await Task.sleep(nanoseconds: pasteConsumeNanoseconds)

            // If Accessibility is still false, keep the transcript on the clipboard so Cmd+V works
            // even when HID events were dropped. AXIsProcessTrusted() can also stay false after a
            // rebuild while Settings still shows ON (stale TCC CDHash).
            let trustedAfterPost = AXIsProcessTrusted()
            if !trustedAfterPost {
                AppLog.line("Paste events posted but trusted=false; leaving transcript on clipboard")
                throw PasteError.needsAccessibility(pastePermissionMessage())
            }

            snapshot.restore(to: pasteboard)
            AppLog.line("Paste clipboard restored after 400ms trusted=true")
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
