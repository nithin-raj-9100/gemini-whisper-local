import ApplicationServices
import AVFoundation
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
        if rightOptionPressTime > 0 {
            hotkeyInterrupted = true
        }
    } else if type == .flagsChanged {
        let isOptionDown = event.flags.contains(.maskAlternate)
        handleModifierChange(keyCode: keyCode, isOptionDown: isOptionDown)
    }

    return Unmanaged.passUnretained(event)
}

if persistent {
    // Listen for commands from the control socket (or audio socket if no control socket)
    let commandDescriptor = controlSocket ?? audioSocket
    if let descriptor = commandDescriptor {
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 64)
            while true {
                let readCount = Darwin.recv(descriptor, &buffer, buffer.count, 0)
                guard readCount > 0 else { break }
                for index in 0..<readCount {
                    let byte = buffer[index]
                    DispatchQueue.main.async {
                        switch byte {
                        case 49: // '1'
                            startCapture()
                        case 48: // '0'
                            if engine.isRunning { engine.pause() }
                        case 113: // 'q'
                            exit(0)
                        default:
                            break
                        }
                    }
                }
            }
            exit(0)
        }
    }

    // AppKit Global Event Monitor
    NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
        let isOptionDown = event.modifierFlags.contains(.option)
        handleModifierChange(keyCode: event.keyCode, isOptionDown: isOptionDown)
    }

    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in
        if rightOptionPressTime > 0 {
            hotkeyInterrupted = true
        }
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
