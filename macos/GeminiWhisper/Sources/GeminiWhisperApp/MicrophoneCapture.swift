@preconcurrency import AVFoundation
import CoreAudio
import Foundation

struct AudioCheckResult: Sendable {
    var source: String
    var bytes: Int
    var rms: Int
    var peak: Int
    var error: String
}

struct PcmMetrics: Sendable {
    var bytes = 0
    var samples = 0
    var sumSquares = 0
    var peak = 0

    mutating func add(_ data: Data) {
        bytes += data.count
        let usable = data.count - (data.count % 2)
        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + 1 < usable {
                let sample = Int16(bitPattern: UInt16(ptr[offset]) | (UInt16(ptr[offset + 1]) << 8))
                let value = Int(sample)
                samples += 1
                sumSquares += value * value
                peak = max(peak, abs(value))
                offset += 2
            }
        }
    }

    var rms: Int {
        samples > 0 ? Int((Double(sumSquares) / Double(samples)).squareRoot().rounded()) : 0
    }
}

/// Persistent `AVAudioEngine` tap converted to 16 kHz Int16 mono, from `macos/audio-helper/main.swift`.
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var reportedConversionError = false
    private var tapInstalled = false
    private let lock = NSLock()
    private var onPCM: ((Data) -> Void)?
    private var diagnosticBuffer: [Data]?

    var isRunning: Bool { engine.isRunning }

    func setPCMHandler(_ handler: @escaping (Data) -> Void) {
        lock.lock()
        onPCM = handler
        lock.unlock()
    }

    func prepare() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noMicrophone
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw CaptureError.converterFailed
        }
        self.outputFormat = format
        self.converter = converter
        installTapIfNeeded(input: input, inputFormat: inputFormat)
        engine.prepare()
    }

    func start() throws {
        if !tapInstalled {
            try prepare()
        }
        guard !engine.isRunning else { return }
        try engine.start()
    }

    func pause() {
        if engine.isRunning {
            engine.pause()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
    }

    /// Capture ~1s of PCM and return RMS/peak, matching `POST /audio-check`.
    func audioCheck(durationNs: UInt64 = 1_000_000_000) async -> AudioCheckResult {
        startDiagnostics()
        do {
            try start()
        } catch {
            clearDiagnostics()
            return AudioCheckResult(
                source: "AVAudioEngine",
                bytes: 0,
                rms: 0,
                peak: 0,
                error: error.localizedDescription
            )
        }
        try? await Task.sleep(nanoseconds: durationNs)
        pause()
        let chunks = takeDiagnostics()

        var combined = Data()
        combined.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
        for chunk in chunks { combined.append(chunk) }
        var metrics = PcmMetrics()
        metrics.add(combined)
        return AudioCheckResult(
            source: "AVAudioEngine default input",
            bytes: metrics.bytes,
            rms: metrics.rms,
            peak: metrics.peak,
            error: ""
        )
    }

    private func startDiagnostics() {
        lock.lock()
        diagnosticBuffer = []
        lock.unlock()
    }

    private func clearDiagnostics() {
        lock.lock()
        diagnosticBuffer = nil
        lock.unlock()
    }

    private func takeDiagnostics() -> [Data] {
        lock.lock()
        let chunks = diagnosticBuffer ?? []
        diagnosticBuffer = nil
        lock.unlock()
        return chunks
    }

    /// Select an input by `AVCaptureDevice.uniqueID`. Empty / `:0` / `default` uses the system default.
    func applyPreferredDevice(uniqueID: String) {
        resetTap()
        if AudioDeviceList.isSystemDefaultPreference(uniqueID) {
            let defaultID = AudioDeviceList.defaultInputDeviceID()
            if defaultID != 0 {
                setInputDevice(defaultID)
            }
            return
        }
        let devices = AudioDeviceList.inputDevices()
        let match = devices.first(where: { $0.uniqueID == uniqueID })
            ?? devices.first(where: { $0.name == uniqueID })
        guard let match, match.audioDeviceID != 0 else { return }
        setInputDevice(match.audioDeviceID)
    }

    private func resetTap() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        converter = nil
        outputFormat = nil
        reportedConversionError = false
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) {
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        var id = deviceID
        _ = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private func installTapIfNeeded(input: AVAudioInputNode, inputFormat: AVAudioFormat) {
        guard !tapInstalled else { return }
        tapInstalled = true
        reportedConversionError = false
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer: buffer, inputFormat: inputFormat)
        }
    }

    private func convert(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let outputFormat, let converter else { return }
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
        let data = Data(bytes: samples, count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
        lock.lock()
        diagnosticBuffer?.append(data)
        let handler = onPCM
        lock.unlock()
        handler?(data)
    }

    enum CaptureError: LocalizedError {
        case noMicrophone
        case converterFailed

        var errorDescription: String? {
            switch self {
            case .noMicrophone:
                return "No default microphone input is available."
            case .converterFailed:
                return "Could not configure 16 kHz PCM conversion."
            }
        }
    }
}

enum AudioDeviceList {
    static let systemDefaultPreference = ""

    /// `:0` and other ffmpeg-style indexes are not AVCapture uniqueIDs — treat them as system default.
    static func normalizedPreference(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return systemDefaultPreference }
        let lowered = trimmed.lowercased()
        if lowered == "default" || lowered == ":0" || trimmed == "0" {
            return systemDefaultPreference
        }
        if trimmed.hasPrefix(":"), Int(trimmed.dropFirst()) != nil {
            return systemDefaultPreference
        }
        if Int(trimmed) != nil {
            return systemDefaultPreference
        }
        return trimmed
    }

    static func isSystemDefaultPreference(_ id: String) -> Bool {
        normalizedPreference(id).isEmpty
    }

    struct Device: Identifiable, Sendable {
        var id: String { uniqueID }
        var name: String
        var uniqueID: String
        var audioDeviceID: AudioDeviceID
        var isDefault: Bool
    }

    static func inputDevices() -> [Device] {
        let captureDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices

        let defaultID = defaultInputDeviceID()
        var result: [Device] = []
        for device in captureDevices {
            let audioID = audioDeviceID(forUID: device.uniqueID) ?? 0
            result.append(
                Device(
                    name: device.localizedName,
                    uniqueID: device.uniqueID,
                    audioDeviceID: audioID,
                    isDefault: audioID != 0 && audioID == defaultID
                )
            )
        }
        return result
    }

    static func defaultInputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var uidCF = uid as CFString
        let status = withUnsafeMutablePointer(to: &uidCF) { uidPtr in
            withUnsafeMutablePointer(to: &deviceID) { idPtr -> OSStatus in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(uidPtr),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(idPtr),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &size,
                    &translation
                )
            }
        }
        return status == noErr && deviceID != 0 ? deviceID : nil
    }
}
