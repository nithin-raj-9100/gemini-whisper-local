import AVFoundation
import Darwin
import Foundation

let permission = AVCaptureDevice.authorizationStatus(for: .audio)
if permission == .notDetermined {
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
    print("Microphone permission granted.")
    exit(0)
}

func argument(after name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

var outputSocket: Int32?
if let portText = argument(after: "--port"), let port = UInt16(portText) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        FileHandle.standardError.write(Data("Could not create the local audio socket.\n".utf8))
        exit(1)
    }
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
        FileHandle.standardError.write(Data("Could not connect to the local Bun audio receiver.\n".utf8))
        Darwin.close(descriptor)
        exit(1)
    }
    outputSocket = descriptor
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
    if let descriptor = outputSocket {
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

if persistent, let descriptor = outputSocket {
    DispatchQueue.global(qos: .userInitiated).async {
        var command: UInt8 = 0
        while Darwin.recv(descriptor, &command, 1, 0) == 1 {
            DispatchQueue.main.async {
                switch command {
                case 49:
                    startCapture()
                case 48:
                    if engine.isRunning { engine.pause() }
                case 113:
                    exit(0)
                default:
                    break
                }
            }
        }
        exit(0)
    }
} else {
    startCapture()
}

RunLoop.current.run()
