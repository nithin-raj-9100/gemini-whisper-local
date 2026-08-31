import ApplicationServices
import AVFoundation
import Carbon
import Cocoa
import CoreGraphics
import Darwin
import Foundation

// Initialize AppKit connection to WindowServer for background event monitoring
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
if micPermission == .notDetermined {
    let semaphore = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in semaphore.signal() }
    semaphore.wait()
}

guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
    FileHandle.standardError.write(
        Data("Gemini Whisper Audio does not have microphone permission. Enable it in System Settings > Privacy & Security > Microphone.\n".utf8)
    )
    exit(77)
}

if CommandLine.arguments.contains("--permission-only") {
    let promptOptions: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    let axTrusted = AXIsProcessTrustedWithOptions(promptOptions)
    if axTrusted {
        print("Microphone and Accessibility permissions granted.")
    } else {
        print("Microphone permission granted. Please grant Accessibility permission in System Settings > Privacy & Security > Accessibility.")
    }
    exit(0)
}

func argument(after name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

func connectSocket(to port: UInt16) -> Int32? {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        Darwin.close(descriptor)
        return nil
    }
    return descriptor
}

var audioSocket: Int32?
if let portText = argument(after: "--port"), let port = UInt16(portText) {
    guard let descriptor = connectSocket(to: port) else {
        FileHandle.standardError.write(Data("Could not connect to the local Bun audio receiver.\n".utf8))
        exit(1)
    }
    audioSocket = descriptor
}

var controlSocket: Int32?
if let portText = argument(after: "--control-port"), let port = UInt16(portText) {
    guard let descriptor = connectSocket(to: port) else {
        FileHandle.standardError.write(Data("Could not connect to the local Bun control receiver.\n".utf8))
        exit(1)
    }
    controlSocket = descriptor
}

func sendControlMessage(_ message: String) {
    guard let descriptor = controlSocket else { return }
    let data = Data(message.utf8)
    _ = data.withUnsafeBytes { bytes in
        Darwin.send(descriptor, bytes.baseAddress, bytes.count, MSG_NOSIGNAL)
    }
}

var lastToggleTriggerTime: UInt64 = 0

func triggerDictationToggle() {
    let now = mach_absolute_time()
    if lastToggleTriggerTime > 0 && timeIntervalSinceAbsoluteTime(lastToggleTriggerTime) < 0.35 {
        return
    }
    lastToggleTriggerTime = now
    sendControlMessage("toggle\n")
}

let engine = AVAudioEngine()
let input = engine.inputNode
let inputFormat = input.outputFormat(forBus: 0)
guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
    FileHandle.standardError.write(Data("No default microphone input is available.\n".utf8))
    exit(1)
}

guard let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: true
), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
    FileHandle.standardError.write(Data("Could not configure 16 kHz PCM conversion.\n".utf8))
    exit(1)
}

let stdout = FileHandle.standardOutput
let persistent = CommandLine.arguments.contains("--persistent")
func writeAudio(_ data: Data) {
    if let descriptor = audioSocket {
        let sent = data.withUnsafeBytes { bytes in
            Darwin.send(descriptor, bytes.baseAddress, bytes.count, MSG_NOSIGNAL)
        }
        if sent <= 0 { exit(0) }
    } else {
        stdout.write(data)
    }
}

var reportedConversionError = false
input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
    let estimatedFrames = ceil(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate) + 8
    guard let converted = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: AVAudioFrameCount(estimatedFrames)
    ) else { return }

    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
        if suppliedInput {
            inputStatus.pointee = .noDataNow
            return nil
        }
        suppliedInput = true
        inputStatus.pointee = .haveData
        return buffer
    }

    if status == .error {
        if !reportedConversionError {
            reportedConversionError = true
            let detail = conversionError?.localizedDescription ?? "unknown conversion error"
            FileHandle.standardError.write(Data("Audio conversion failed: \(detail)\n".utf8))
        }
        return
    }
    guard converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }
    writeAudio(Data(bytes: samples, count: Int(converted.frameLength) * MemoryLayout<Int16>.size))
}

engine.prepare()

func startCapture() {
    guard !engine.isRunning else { return }
    do {
        try engine.start()
    } catch {
        FileHandle.standardError.write(Data("Could not start microphone capture: \(error.localizedDescription)\n".utf8))
    }
}

// Virtual key codes on macOS
let kVK_RightOption: UInt16 = 61
let kVK_LeftOption: UInt16 = 58
let kVK_Escape: UInt16 = 53
var rightOptionPressTime: UInt64 = 0
var hotkeyInterrupted = false

func timeIntervalSinceAbsoluteTime(_ time: UInt64) -> Double {
    var timebaseInfo = mach_timebase_info()
    mach_timebase_info(&timebaseInfo)
    let elapsedNano = (mach_absolute_time() - time) * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
    return Double(elapsedNano) / 1_000_000_000.0
}

func handleModifierChange(keyCode: UInt16, isOptionDown: Bool) {
    if keyCode == kVK_RightOption || keyCode == kVK_LeftOption {
        if isOptionDown {
            rightOptionPressTime = mach_absolute_time()
            hotkeyInterrupted = false
        } else if rightOptionPressTime > 0 {
            let duration = timeIntervalSinceAbsoluteTime(rightOptionPressTime)
            if !hotkeyInterrupted && duration <= 0.6 {
                triggerDictationToggle()
            }
            rightOptionPressTime = 0
            hotkeyInterrupted = false
        }
    } else if rightOptionPressTime > 0 {
        hotkeyInterrupted = true
    }
}

// Carbon Global Event HotKey for Escape (OS-level dispatch without accessibility restriction)
var escapeHotKeyRef: EventHotKeyRef?
let escapeHotKeyID = EventHotKeyID(signature: OSType(0x47574553), id: 1) // 'GWES', 1

func registerEscapeHotKey() {
    guard escapeHotKeyRef == nil else { return }
    var hotKeyRef: EventHotKeyRef?
    let status = RegisterEventHotKey(
        UInt32(kVK_Escape),
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

func setupCarbonHotKeyHandler() {
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
        GetEventDispatcherTarget(),
        { (nextHandler, theEvent, userData) -> OSStatus in
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
                    handleEscapeKey()
                }
                return noErr
            }
            return CallNextEventHandler(nextHandler, theEvent)
        },
        1,
        &eventType,
        nil,
        nil
    )
}

func handleEscapeKey() {
    unregisterEscapeHotKey()
    hudController.hide()
    if engine.isRunning { engine.pause() }
    sendControlMessage("cancel\n")
}

var globalEventTap: CFMachPort?

let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

    if type == .keyDown {
        if keyCode == kVK_Escape {
            DispatchQueue.main.async {
                handleEscapeKey()
            }
        } else if rightOptionPressTime > 0 {
            hotkeyInterrupted = true
        }
    } else if type == .flagsChanged {
        let isOptionDown = event.flags.contains(.maskAlternate)
        DispatchQueue.main.async {
            handleModifierChange(keyCode: keyCode, isOptionDown: isOptionDown)
        }
    }

    return Unmanaged.passUnretained(event)
}

import QuartzCore

final class FloatingHUDController: NSObject {
    private var window: NSPanel?
    private var visualEffectView: NSVisualEffectView?
    private var statusDot: NSView?
    private var statusLabel: NSTextField?
    private var scrollView: NSScrollView?
    private var textView: NSTextView?
    private var currentText: String = ""
    private(set) var isCurrentlyActive: Bool = false
    private let defaultWidth: CGFloat = 520
    private let baseHeight: CGFloat = 72
    private let maxTextHeight: CGFloat = 180

    override init() {
        super.init()
        setupWindow()
    }

    private func setupWindow() {
        let width = defaultWidth
        let height = baseHeight

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0.0
        panel.isReleasedWhenClosed = false

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffect.material = .hudWindow
        visualEffect.appearance = NSAppearance(named: .vibrantDark)
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 18
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor(white: 1.0, alpha: 0.18).cgColor
        visualEffect.autoresizingMask = [.width, .height]

        // Status Row (Indicator Dot + Label)
        let dot = NSView(frame: NSRect(x: 16, y: height - 26, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.0
        dot.layer?.backgroundColor = NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0).cgColor

        let label = NSTextField(labelWithString: "Listening…")
        label.frame = NSRect(x: 30, y: height - 31, width: 220, height: 18)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor(white: 1.0, alpha: 0.65)

        // Scroll view & text view for auto-wrapping, auto-scrolling long transcripts
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 12, width: width - 32, height: 28))
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = false
        tv.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        tv.textColor = NSColor(white: 1.0, alpha: 0.5)
        tv.string = "Speak now…"
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: width - 32, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        scroll.documentView = tv

        visualEffect.addSubview(dot)
        visualEffect.addSubview(label)
        visualEffect.addSubview(scroll)

        panel.contentView = visualEffect
        self.window = panel
        self.visualEffectView = visualEffect
        self.statusDot = dot
        self.statusLabel = label
        self.scrollView = scroll
        self.textView = tv
    }

    private func targetScreen() -> NSScreen {
        let mouseLoc = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first!
    }

    private func updatePositionAndSize(animated: Bool = false) {
        guard let window = self.window, let scrollView = self.scrollView, let statusDot = self.statusDot, let statusLabel = self.statusLabel, let textView = self.textView else { return }

        let screen = targetScreen()
        let screenFrame = screen.visibleFrame
        let width = defaultWidth
        let horizontalPadding: CGFloat = 32.0
        let availableWidth = width - horizontalPadding

        let displayText = currentText.isEmpty ? "Speak now…" : currentText
        let font = NSFont.systemFont(ofSize: 14, weight: .regular)
        let attrString = NSAttributedString(string: displayText, attributes: [.font: font])
        let bounds = attrString.boundingRect(
            with: NSSize(width: availableWidth, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let textHeight = max(24, min(ceil(bounds.height) + 4, maxTextHeight))
        let totalHeight = 32 + textHeight + 14

        let x = screenFrame.origin.x + (screenFrame.width - width) / 2.0
        let y = screenFrame.origin.y + 60.0

        let newFrame = NSRect(x: x, y: y, width: width, height: totalHeight)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
                window.animator().setFrame(newFrame, display: true)
            }
        } else {
            window.setFrame(newFrame, display: true)
        }

        statusDot.frame = NSRect(x: 16, y: totalHeight - 26, width: 8, height: 8)
        statusLabel.frame = NSRect(x: 30, y: totalHeight - 31, width: 220, height: 18)
        scrollView.frame = NSRect(x: 16, y: 12, width: availableWidth, height: textHeight)
        textView.scrollToEndOfDocument(nil)
    }

    func show() {
        guard let window = self.window else { return }
        registerEscapeHotKey()
        self.currentText = ""
        self.textView?.string = "Speak now…"
        self.textView?.textColor = NSColor(white: 1.0, alpha: 0.5)
        self.setState("listening")
        self.updatePositionAndSize(animated: false)

        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1.0
        }
        self.isCurrentlyActive = true
        self.startPulsing()
    }

    func hide() {
        unregisterEscapeHotKey()
        guard let window = self.window, self.isCurrentlyActive else { return }
        self.isCurrentlyActive = false
        self.stopPulsing()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().alphaValue = 0.0
        }, completionHandler: {
            if !self.isCurrentlyActive {
                window.orderOut(nil)
            }
        })
    }

    func updateText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentText = trimmed
        if trimmed.isEmpty {
            self.textView?.string = "Listening…"
            self.textView?.textColor = NSColor(white: 1.0, alpha: 0.5)
        } else {
            self.textView?.string = trimmed
            self.textView?.textColor = NSColor(white: 1.0, alpha: 0.95)
        }
        self.updatePositionAndSize(animated: true)
    }

    func setState(_ state: String) {
        switch state.lowercased() {
        case "polishing":
            self.statusLabel?.stringValue = "Polishing with Gemini…"
            self.statusDot?.layer?.backgroundColor = NSColor(red: 0.65, green: 0.45, blue: 1.0, alpha: 1.0).cgColor
            self.stopPulsing()
        case "error":
            self.statusLabel?.stringValue = "Error"
            self.statusDot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
            self.stopPulsing()
        default:
            self.statusLabel?.stringValue = "Listening…"
            self.statusDot?.layer?.backgroundColor = NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0).cgColor
            self.startPulsing()
        }
    }

    private func startPulsing() {
        guard let layer = self.statusDot?.layer else { return }
        layer.removeAnimation(forKey: "pulse")
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.duration = 0.8
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer.add(pulse, forKey: "pulse")
    }

    private func stopPulsing() {
        self.statusDot?.layer?.removeAnimation(forKey: "pulse")
        self.statusDot?.layer?.opacity = 1.0
    }
}

let hudController = FloatingHUDController()

func handleCommand(_ line: String) {
    if line == "1" {
        startCapture()
        if !hudController.isCurrentlyActive {
            hudController.show()
        }
    } else if line == "0" {
        if engine.isRunning { engine.pause() }
    } else if line == "q" {
        exit(0)
    } else if line == "hud:show" {
        if !hudController.isCurrentlyActive {
            hudController.show()
        }
    } else if line == "hud:hide" {
        hudController.hide()
    } else if line.hasPrefix("hud:state ") {
        let state = String(line.dropFirst("hud:state ".count))
        hudController.setState(state)
    } else if line.hasPrefix("hud:text ") {
        let b64 = String(line.dropFirst("hud:text ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf8) {
            hudController.updateText(text)
        }
    }
}

if persistent {
    // Listen for commands from the control socket (or audio socket if no control socket)
    let commandDescriptor = controlSocket ?? audioSocket
    if let descriptor = commandDescriptor {
        DispatchQueue.global(qos: .userInitiated).async {
            var lineBuffer = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let readCount = Darwin.recv(descriptor, &buffer, buffer.count, 0)
                guard readCount > 0 else { break }
                lineBuffer.append(contentsOf: buffer[0..<readCount])

                while let newlineIndex = lineBuffer.firstIndex(of: 10) {
                    let lineData = lineBuffer.subdata(in: 0..<newlineIndex)
                    lineBuffer.removeSubrange(0...newlineIndex)
                    if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                        DispatchQueue.main.async {
                            handleCommand(line)
                        }
                    }
                }

                if lineBuffer.count == 1 {
                    let byte = lineBuffer[0]
                    if byte == 49 {
                        lineBuffer.removeAll()
                        DispatchQueue.main.async { handleCommand("1") }
                    } else if byte == 48 {
                        lineBuffer.removeAll()
                        DispatchQueue.main.async { handleCommand("0") }
                    } else if byte == 113 {
                        exit(0)
                    }
                }
            }
            exit(0)
        }
    }

    // Setup Carbon HotKey Handler for global Escape detection
    setupCarbonHotKeyHandler()

    // AppKit Global Event Monitor
    NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
        let isOptionDown = event.modifierFlags.contains(.option)
        handleModifierChange(keyCode: event.keyCode, isOptionDown: isOptionDown)
    }

    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
        if event.keyCode == kVK_Escape {
            handleEscapeKey()
        } else if rightOptionPressTime > 0 {
            hotkeyInterrupted = true
        }
    }

    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.keyCode == kVK_Escape {
            handleEscapeKey()
            return nil
        }
        return event
    }

    // CoreGraphics CGEventTap as parallel monitor
    let eventsOfInterest: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

    if let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: eventsOfInterest,
        callback: eventTapCallback,
        userInfo: nil
    ) {
        globalEventTap = eventTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
} else {
    startCapture()
}

app.run()
