import ApplicationServices
import Carbon
import Cocoa
import CoreGraphics
import Darwin
import GeminiWhisperCore

nonisolated(unsafe) private var hotkeyEventTapPort: CFMachPort?

/// The configured hotkey (Right Option by default): a tap toggles; holding for
/// 0.6s records until release. Escape cancels. Using the key as a modifier
/// cancels that gesture.
/// Carbon hotkey + NSEvent monitors + CGEventTap. The event tap retries until
/// Accessibility is granted and is re-validated after sleep.
final class HotkeyMonitor: @unchecked Sendable {
    static let shared = HotkeyMonitor()

    var onPrepare: (() -> Void)?
    var onDiscardPreparation: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    var onHoldCancel: (() -> Void)?
    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Called on the main thread when the event tap is (re)installed.
    var onEventTapChanged: (() -> Void)?
    private(set) var eventTapInstalled = false
    private(set) var eventTapFailureMessage: String?

    /// Changing the key abandons any gesture in progress on the old one.
    var hotkey: HotkeyKey = .rightOption {
        didSet {
            guard hotkey != oldValue else { return }
            interruptGesture()
            gesture = OptionKeyGesture()
            hotkeyPressTime = 0
        }
    }

    private let kVKEscape: UInt16 = 53

    private var lastToggleTriggerTime: TimeInterval = 0
    private var hotkeyPressTime: TimeInterval = 0
    /// Key-down uptime of the last completed tap or hold, for felt latency.
    private(set) var lastTapDownUptime: TimeInterval = 0
    private var gesture = OptionKeyGesture()
    private var holdTask: Task<Void, Never>?
    private var escapeHotKeyRef: EventHotKeyRef?
    private let escapeHotKeyID = EventHotKeyID(signature: OSType(0x47574553), id: 1)
    private var globalEventTap: CFMachPort? {
        get { hotkeyEventTapPort }
        set { hotkeyEventTapPort = newValue }
    }
    private var eventTapSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var carbonHandlerInstalled = false
    private var monitorsInstalled = false
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalFlagsMonitor: Any?

    private init() {}

    func start() {
        installMonitorsIfNeeded()
        setupCarbonHotKeyHandler()
        installEventTap()
    }

    func stop() {
        interruptGesture()
        gesture = OptionKeyGesture()
        hotkeyPressTime = 0
        retryTimer?.invalidate()
        retryTimer = nil
        unregisterEscapeHotKey()
        if let tap = globalEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        localKeyMonitor = nil
        globalKeyMonitor = nil
        globalFlagsMonitor = nil
        monitorsInstalled = false
    }

    func registerEscapeHotKey() {
        guard escapeHotKeyRef == nil else { return }
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVKEscape),
            0,
            escapeHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            escapeHotKeyRef = hotKeyRef
        }
    }

    func unregisterEscapeHotKey() {
        if let ref = escapeHotKeyRef {
            UnregisterEventHotKey(ref)
            escapeHotKeyRef = nil
        }
    }

    fileprivate func triggerDictationToggle() {
        let now = ProcessInfo.processInfo.systemUptime
        if lastToggleTriggerTime > 0 && now - lastToggleTriggerTime < 0.35 {
            return
        }
        lastToggleTriggerTime = now
        onToggle?()
    }

    fileprivate func handleEscapeKey() {
        interruptGesture()
        unregisterEscapeHotKey()
        onCancel?()
    }

    /// `flags` are the raw modifier flags; the configured key's device bit tells
    /// whether it is down, independent of the matching key on the other side.
    fileprivate func handleModifierChange(keyCode: UInt16, flags: UInt64) {
        if keyCode == hotkey.keyCode {
            if hotkey.isDown(flags: flags) {
                let now = ProcessInfo.processInfo.systemUptime
                let actions = gesture.press(at: now)
                guard !actions.isEmpty else { return } // duplicate event-tap/NSEvent delivery
                hotkeyPressTime = now
                holdTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    let actions = self.gesture.advance(to: ProcessInfo.processInfo.systemUptime)
                    self.perform(actions)
                }
                perform(actions)
            } else {
                holdTask?.cancel()
                holdTask = nil
                perform(gesture.release(at: ProcessInfo.processInfo.systemUptime))
                onDiscardPreparation?()
                hotkeyPressTime = 0
            }
        } else if hotkeyPressTime > 0 {
            interruptGesture()
        }
    }

    private func perform(_ actions: [OptionKeyGesture.Action]) {
        for action in actions {
            switch action {
            case .prepare: onPrepare?()
            case .toggle:
                lastTapDownUptime = hotkeyPressTime
                triggerDictationToggle()
            case .startHold:
                lastTapDownUptime = hotkeyPressTime
                onHoldStart?()
            case .finishHold: onHoldEnd?()
            case .discardPreparation: onDiscardPreparation?()
            case .cancelHold: onHoldCancel?()
            }
        }
    }

    private func interruptGesture() {
        holdTask?.cancel()
        holdTask = nil
        perform(gesture.interrupt())
    }

    fileprivate func noteKeyDown(keyCode: UInt16) {
        if keyCode == kVKEscape {
            handleEscapeKey()
        } else if hotkeyPressTime > 0 {
            interruptGesture()
        }
    }

    fileprivate var eventTap: CFMachPort? {
        get { hotkeyEventTapPort }
        set { hotkeyEventTapPort = newValue }
    }

    private func installMonitorsIfNeeded() {
        guard !monitorsInstalled else { return }
        monitorsInstalled = true

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = UInt64(event.modifierFlags.rawValue)
            let keyCode = event.keyCode
            DispatchQueue.main.async {
                self?.handleModifierChange(keyCode: keyCode, flags: flags)
            }
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            DispatchQueue.main.async {
                self?.noteKeyDown(keyCode: keyCode)
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.noteKeyDown(keyCode: event.keyCode)
            return event.keyCode == self?.kVKEscape ? nil : event
        }
    }

    private func setupCarbonHotKeyHandler() {
        guard !carbonHandlerInstalled else { return }
        carbonHandlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, theEvent, _) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    theEvent,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if status == noErr && hotKeyID.id == 1 {
                    DispatchQueue.main.async {
                        HotkeyMonitor.shared.handleEscapeKey()
                    }
                    return noErr
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }

    private func installEventTap() {
        guard globalEventTap == nil else { return }
        let eventsOfInterest: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventsOfInterest,
            callback: hotkeyEventTapCallback,
            userInfo: nil
        ) else {
            if eventTapFailureMessage == nil {
                FileHandle.standardError.write(Data("CGEvent.tapCreate failed. Accessibility is required for the dictation hotkey.\n".utf8))
            }
            eventTapInstalled = false
            eventTapFailureMessage =
                "Could not create the keyboard event tap. Grant Accessibility to Gemini Whisper in System Settings → Privacy & Security → Accessibility; the app retries automatically."
            scheduleRetry()
            return
        }
        globalEventTap = eventTap
        eventTapInstalled = true
        eventTapFailureMessage = nil
        retryTimer?.invalidate()
        retryTimer = nil
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        eventTapSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        onEventTapChanged?()
    }

    /// Accessibility is often granted after launch; pick it up without a restart.
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.installEventTap()
        }
    }

    func retryEventTap() {
        installEventTap()
    }

    /// After sleep or a permission change the tap can be disabled or invalidated
    /// while the app keeps running; re-enable or rebuild it.
    func revalidate() {
        guard let tap = globalEventTap else {
            installEventTap()
            return
        }
        if !CFMachPortIsValid(tap) {
            if let eventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            }
            eventTapSource = nil
            globalEventTap = nil
            eventTapInstalled = false
            installEventTap()
        } else if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}

private let hotkeyEventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = HotkeyMonitor.shared.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    if type == .keyDown {
        DispatchQueue.main.async {
            HotkeyMonitor.shared.noteKeyDown(keyCode: keyCode)
        }
    } else if type == .flagsChanged {
        let flags = event.flags.rawValue
        DispatchQueue.main.async {
            HotkeyMonitor.shared.handleModifierChange(keyCode: keyCode, flags: flags)
        }
    }
    return Unmanaged.passUnretained(event)
}

func timeIntervalSinceAbsoluteTime(_ time: UInt64) -> Double {
    var timebaseInfo = mach_timebase_info()
    mach_timebase_info(&timebaseInfo)
    let elapsedNano = (mach_absolute_time() - time) * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
    return Double(elapsedNano) / 1_000_000_000.0
}
