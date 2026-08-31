import ApplicationServices
import Carbon
import Cocoa
import CoreGraphics
import Darwin

nonisolated(unsafe) private var hotkeyEventTapPort: CFMachPort?

/// Left and Right Option taps (≤0.6s, not interrupted, 350ms debounce) plus Escape cancel.
/// Mirrors `macos/audio-helper/main.swift`: Carbon hotkey + NSEvent monitors + CGEventTap.
final class HotkeyMonitor: @unchecked Sendable {
    static let shared = HotkeyMonitor()

    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var eventTapInstalled = false
    private(set) var eventTapFailureMessage: String?

    private let kVKRightOption: UInt16 = 61
    private let kVKLeftOption: UInt16 = 58
    private let kVKEscape: UInt16 = 53

    private var lastToggleTriggerTime: UInt64 = 0
    private var optionPressTime: UInt64 = 0
    private var hotkeyInterrupted = false
    private var escapeHotKeyRef: EventHotKeyRef?
    private let escapeHotKeyID = EventHotKeyID(signature: OSType(0x47574553), id: 1)
    private var globalEventTap: CFMachPort? {
        get { hotkeyEventTapPort }
        set { hotkeyEventTapPort = newValue }
    }
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
        let now = mach_absolute_time()
        if lastToggleTriggerTime > 0 && timeIntervalSinceAbsoluteTime(lastToggleTriggerTime) < 0.35 {
            return
        }
        lastToggleTriggerTime = now
        onToggle?()
    }

    fileprivate func handleEscapeKey() {
        unregisterEscapeHotKey()
        onCancel?()
    }

    fileprivate func handleModifierChange(keyCode: UInt16, isOptionDown: Bool) {
        if keyCode == kVKRightOption || keyCode == kVKLeftOption {
            if isOptionDown {
                optionPressTime = mach_absolute_time()
                hotkeyInterrupted = false
            } else if optionPressTime > 0 {
                let duration = timeIntervalSinceAbsoluteTime(optionPressTime)
                if !hotkeyInterrupted && duration <= 0.6 {
                    triggerDictationToggle()
                }
                optionPressTime = 0
                hotkeyInterrupted = false
            }
        } else if optionPressTime > 0 {
            hotkeyInterrupted = true
        }
    }

    fileprivate func noteKeyDown(keyCode: UInt16) {
        if keyCode == kVKEscape {
            handleEscapeKey()
        } else if optionPressTime > 0 {
            hotkeyInterrupted = true
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
            let isOptionDown = event.modifierFlags.contains(.option)
            let keyCode = event.keyCode
            DispatchQueue.main.async {
                self?.handleModifierChange(keyCode: keyCode, isOptionDown: isOptionDown)
            }
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            DispatchQueue.main.async {
                self?.noteKeyDown(keyCode: keyCode)
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == self?.kVKEscape {
                self?.handleEscapeKey()
                return nil
            }
            return event
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
            eventTapInstalled = false
            eventTapFailureMessage =
                "Could not create the keyboard event tap. Grant Accessibility to Gemini Whisper in System Settings → Privacy & Security → Accessibility, then restart the app or retry below."
            FileHandle.standardError.write(Data("CGEvent.tapCreate failed. Accessibility is required for Right Option.\n".utf8))
            return
        }
        globalEventTap = eventTap
        eventTapInstalled = true
        eventTapFailureMessage = nil
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func retryEventTap() {
        installEventTap()
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
        let isOptionDown = event.flags.contains(.maskAlternate)
        DispatchQueue.main.async {
            HotkeyMonitor.shared.handleModifierChange(keyCode: keyCode, isOptionDown: isOptionDown)
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
