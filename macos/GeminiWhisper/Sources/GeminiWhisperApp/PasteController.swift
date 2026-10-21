import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import GeminiWhisperCore

/// In-process paste: NSPasteboard + synthesized Cmd+V from this process (not osascript),
/// with Accessibility used to check where the text is going and whether it arrived.
@MainActor
final class PasteController: TextInserting {
    static let shared = PasteController()

    /// kVK_ANSI_V
    private static let keyCodeV: CGKeyCode = 0x09
    /// kVK_Command
    private static let keyCodeCommand: CGKeyCode = 0x37
    /// Floor before Cmd+V: the readback below proves *our* view of the pasteboard,
    /// but the target process still has to observe the change. Kept small and
    /// polled up to the cap instead of always paying the worst case.
    private static let pasteboardSettleFloorNanoseconds: UInt64 = 8_000_000
    private static let pasteboardSettleCapNanoseconds: UInt64 = 50_000_000
    private static let pasteboardPollNanoseconds: UInt64 = 2_000_000
    /// How long the target may take to read the pasteboard before the user's own
    /// clipboard comes back. Electron apps, VMs, and remote desktops read lazily;
    /// the change-count guard makes a generous delay safe.
    private static let restoreDelayNanoseconds: UInt64 = 1_500_000_000
    /// When to check whether the focused field actually changed.
    private static let verifyDelayNanoseconds: UInt64 = 500_000_000

    private var pendingRestore: (snapshot: ClipboardSnapshot, changeCount: Int, task: Task<Void, Never>)?
    private var userInputMonitor: Any?

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

    // MARK: - TextInserting

    func currentTarget() -> InsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return InsertionTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
        )
    }

    func insert(_ text: String, expected: InsertionTarget?,
                onNotInserted: @escaping @MainActor @Sendable (String) -> Void) async throws -> InsertionReport {
        let trustedAtStart = AXIsProcessTrusted()
        let current = currentTarget()
        AppLog.line(
            "Paste begin trusted=\(trustedAtStart) executable=\(Self.runningIdentity) chars=\(text.count) " +
                "frontmost=\(current?.name ?? "nil") pid=\(current?.processIdentifier ?? 0) expected=\(expected?.name ?? "nil")"
        )
        if !trustedAtStart {
            _ = Self.promptAccessibilityIfNeeded()
        }

        if current?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            try copy(text)
            AppLog.line("Paste skipped; Gemini Whisper is frontmost. Copied to clipboard.")
            return .copied(reason: "Gemini Whisper was frontmost")
        }
        if let expected, let current, expected.processIdentifier != current.processIdentifier {
            AppLog.line("Focus moved \(expected.name) -> \(current.name); pasting into the focused app")
        }

        let focus = FocusedElement.current()
        if focus.isSecure {
            try copy(text)
            AppLog.line("Paste skipped; a password field is focused. Copied to clipboard.")
            return .copied(reason: "a password field was focused")
        }
        // Secure Event Input (password fields, Terminal's Secure Keyboard Entry,
        // some password managers) can swallow synthetic keystrokes.
        let secureInput = IsSecureEventInputEnabled()

        let pasteboard = NSPasteboard.general
        let (snapshot, changeCount) = writeTranscript(text, to: pasteboard)
        guard pasteboard.string(forType: .string) == text else {
            snapshot.restore(to: pasteboard, ifChangeCount: pasteboard.changeCount)
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
            if !AXIsProcessTrusted() {
                AppLog.line("Paste events posted but trusted=false; leaving transcript on clipboard")
                throw PasteError.needsAccessibility(Self.pastePermissionMessage())
            }
        } catch let error as PasteError {
            if case .needsAccessibility = error { throw error }
            snapshot.restore(to: pasteboard, ifChangeCount: changeCount)
            AppLog.line("Paste failed: \(error.localizedDescription)")
            throw error
        } catch {
            snapshot.restore(to: pasteboard, ifChangeCount: changeCount)
            AppLog.line("Paste failed: \(error.localizedDescription)")
            throw error
        }

        // Give the user's clipboard back only when the destination is known to take
        // text. Otherwise keep the transcript there, so Cmd+V recovers it if the
        // posted keystrokes went nowhere.
        if focus.isEditable && !secureInput {
            scheduleRestore(snapshot, changeCount: changeCount)
            AppLog.line("Paste Cmd+V posted into \(focus.role ?? "an editable field"); clipboard restore scheduled")
        } else {
            AppLog.line("Paste Cmd+V posted; transcript kept on the clipboard (\(secureInput ? "secure input is active" : "no editable field confirmed through Accessibility")).")
        }

        if let element = focus.element, let before = focus.characterCount {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.verifyDelayNanoseconds)
                guard let after = FocusedElement.characterCount(of: element), after == before else { return }
                self.cancelRestore(changeCount: changeCount)
                AppLog.line("Paste not confirmed: the focused field still has \(after) characters; transcript kept on the clipboard.")
                onNotInserted(text)
            }
        }
        return .pasted
    }

    /// Replaces the text this app just inserted, but only after Accessibility
    /// confirms that the characters before the caret are exactly that text. Auto-
    /// formatting editors, terminals, and apps without text Accessibility fail the
    /// check and keep the inserted raw text instead of losing the user's own text.
    func replaceInserted(_ inserted: String, with replacement: String, target: InsertionTarget?) async throws -> Bool {
        guard AXIsProcessTrusted() else {
            throw PasteError.needsAccessibility(Self.pastePermissionMessage())
        }
        if let target, currentTarget()?.processIdentifier != target.processIdentifier {
            AppLog.line("Repair skipped; focus moved away from \(target.name).")
            return false
        }
        let focus = FocusedElement.current()
        guard let element = focus.element, !focus.isSecure,
              let caret = FocusedElement.selectedRange(of: element), caret.length == 0
        else {
            AppLog.line("Repair skipped; the focused field does not report a caret position.")
            return false
        }
        let length = (inserted as NSString).length
        guard caret.location >= length else {
            AppLog.line("Repair skipped; the caret is before the inserted text.")
            return false
        }
        let range = CFRange(location: caret.location - length, length: length)
        guard FocusedElement.string(for: range, in: element) == inserted else {
            AppLog.line("Repair skipped; the text before the caret no longer matches what was inserted.")
            return false
        }
        guard FocusedElement.select(range, in: element),
              FocusedElement.string(element, kAXSelectedTextAttribute) == inserted
        else {
            AppLog.line("Repair skipped; the inserted text could not be selected.")
            return false
        }

        let pasteboard = NSPasteboard.general
        let (snapshot, changeCount) = writeTranscript(replacement, to: pasteboard)
        do {
            _ = try await awaitPasteboardSettled(replacement, on: pasteboard)
            try postCommandV()
        } catch {
            snapshot.restore(to: pasteboard, ifChangeCount: changeCount)
            AppLog.line("Repair failed: \(error.localizedDescription)")
            throw error
        }
        scheduleRestore(snapshot, changeCount: changeCount)
        AppLog.line("Repair replaced \(inserted.count) characters with \(replacement.count) through an Accessibility selection.")
        return true
    }

    /// A deliberate copy: stays on the clipboard and is not marked transient, so
    /// clipboard managers keep it as a recovery path.
    func copy(_ text: String) throws {
        pendingRestore?.task.cancel()
        pendingRestore = nil
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw PasteError.failed("Could not copy the transcript.")
        }
    }

    func startUserInputWatch(_ onInput: @escaping @MainActor @Sendable () -> Void) {
        stopUserInputWatch()
        userInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in onInput() }
        }
    }

    func stopUserInputWatch() {
        if let userInputMonitor {
            NSEvent.removeMonitor(userInputMonitor)
        }
        userInputMonitor = nil
    }

    // MARK: - Clipboard

    /// Writes the transcript and returns the snapshot to restore plus our change count.
    /// While an earlier transcript is still waiting to be swapped back, its snapshot
    /// is reused: a second dictation must restore the user's clipboard, not the
    /// first transcript.
    private func writeTranscript(_ text: String, to pasteboard: NSPasteboard) -> (ClipboardSnapshot, Int) {
        let original: ClipboardSnapshot
        if let pending = pendingRestore, pasteboard.changeCount == pending.changeCount {
            pending.task.cancel()
            original = pending.snapshot
            ClipboardSnapshot.writeTransientString(text, to: pasteboard)
        } else {
            pendingRestore?.task.cancel()
            original = ClipboardSnapshot.replaceString(text, on: pasteboard)
        }
        pendingRestore = nil
        return (original, pasteboard.changeCount)
    }

    private func scheduleRestore(_ snapshot: ClipboardSnapshot, changeCount: Int) {
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.restoreDelayNanoseconds)
            guard !Task.isCancelled else { return }
            let restored = snapshot.restore(to: .general, ifChangeCount: changeCount)
            AppLog.line(restored ? "Clipboard restored." : "Clipboard restore skipped; the clipboard changed after the paste.")
            if self?.pendingRestore?.changeCount == changeCount {
                self?.pendingRestore = nil
            }
        }
        pendingRestore = (snapshot, changeCount, task)
    }

    private func cancelRestore(changeCount: Int) {
        guard let pending = pendingRestore, pending.changeCount == changeCount else { return }
        pending.task.cancel()
        pendingRestore = nil
    }

    /// Sleep the floor, then poll until the write reads back, up to the cap.
    /// Returns the nanoseconds actually waited.
    private func awaitPasteboardSettled(_ text: String, on pasteboard: NSPasteboard) async throws -> UInt64 {
        try await Task.sleep(nanoseconds: Self.pasteboardSettleFloorNanoseconds)
        var waited = Self.pasteboardSettleFloorNanoseconds
        while waited < Self.pasteboardSettleCapNanoseconds {
            if pasteboard.string(forType: .string) == text { return waited }
            try await Task.sleep(nanoseconds: Self.pasteboardPollNanoseconds)
            waited += Self.pasteboardPollNanoseconds
        }
        return waited
    }

    // MARK: - Keystrokes

    private func postCommandV() throws {
        let source: CGEventSource
        if let hid = CGEventSource(stateID: .hidSystemState) {
            source = hid
        } else if let combined = CGEventSource(stateID: .combinedSessionState) {
            source = combined
            AppLog.line("Paste CGEventSource hidSystemState nil; using combinedSessionState")
        } else {
            AppLog.line("Paste CGEventSource creation failed (hidSystemState and combinedSessionState)")
            throw eventFailure("Could not create a keyboard event source for Cmd+V.")
        }
        source.localEventsSuppressionInterval = 0

        guard
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: Self.keyCodeCommand, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: Self.keyCodeV, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: Self.keyCodeV, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: Self.keyCodeCommand, keyDown: false)
        else {
            AppLog.line("Paste CGEvent keyboard events not created")
            throw eventFailure("Could not create Cmd+V keyboard events.")
        }

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

    private func eventFailure(_ detail: String) -> PasteError {
        if AXIsProcessTrusted() {
            return .failed("\(detail) Accessibility is granted; Cmd+V was not posted.")
        }
        return .needsAccessibility(Self.pastePermissionMessage())
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

/// The focused UI element of the frontmost app, read through Accessibility with a
/// short timeout so a hung app cannot stall dictation.
struct FocusedElement {
    var element: AXUIElement?
    var role: String?
    var subrole: String?
    var valueSettable = false
    var characterCount: Int?

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let messagingTimeout: Float = 0.25

    var isSecure: Bool { subrole == kAXSecureTextFieldSubrole }

    var isEditable: Bool {
        guard element != nil else { return false }
        return valueSettable || (role.map { Self.textRoles.contains($0) } ?? false)
    }

    static func current() -> FocusedElement {
        guard AXIsProcessTrusted() else { return FocusedElement() }
        let system = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return FocusedElement()
        }
        let element = value as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var focused = FocusedElement(element: element)
        focused.role = string(element, kAXRoleAttribute)
        focused.subrole = string(element, kAXSubroleAttribute)
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success {
            focused.valueSettable = settable.boolValue
        }
        focused.characterCount = characterCount(of: element)
        return focused
    }

    static func characterCount(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func string(for range: CFRange, in element: AXUIElement) -> String? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    static func select(_ range: CFRange, in element: AXUIElement) -> Bool {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, parameter) == .success
    }
}
