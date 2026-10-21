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

/// Persistent `AVAudioEngine` tap converted to 16 kHz Int16 mono.
///
/// Survives device changes: plugging in or removing a headset, switching the
/// system default input, or a sample-rate change stops the engine and changes the
/// input format. The engine's configuration-change notification and Core Audio
/// device listeners rebuild the tap for the current device and restart capture if
/// it was running, and the converter follows each buffer's actual format.
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let conversionLock = NSLock()
    private var acceptingAudio = false
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var reportedConversionError = false
    private var tapInstalled = false
    private let lock = NSLock()
    private var onPCM: ((Data) -> Void)?
    private var diagnosticBuffer: [Data]?
    private var lastDevicePreference: String?
    private var currentDeviceID: AudioDeviceID = 0
    private var needsRebuild = false
    private var configurationObserver: NSObjectProtocol?
    private var listenersInstalled = false

    var isRunning: Bool { engine.isRunning }

    /// Display name of the input in use, for "no signal" messages.
    var currentDeviceName: String {
        let id = currentDeviceID != 0 ? currentDeviceID : AudioDeviceList.defaultInputDeviceID()
        return AudioDeviceList.name(of: id) ?? "the microphone"
    }

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange(reason: "audio engine configuration changed")
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func setPCMHandler(_ handler: @escaping (Data) -> Void) {
        lock.lock()
        onPCM = handler
        lock.unlock()
    }

    func prepare() throws {
        installDeviceListenersIfNeeded()
        guard !tapInstalled else { return }
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noMicrophone
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw CaptureError.converterFailed
        }
        conversionLock.withLock {
            outputFormat = format
            converter = nil
        }
        tapInstalled = true
        reportedConversionError = false
        // nil format: the tap uses the bus's current format. Passing a cached
        // format that no longer matches the hardware raises an exception.
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            self?.convert(buffer: buffer)
        }
        engine.prepare()
    }

    func start() throws {
        if needsRebuild {
            rebuild(reason: "pending device change")
        }
        if !tapInstalled {
            try prepare()
        }
        guard !engine.isRunning else { return }
        conversionLock.withLock { acceptingAudio = true }
        do {
            try engine.start()
        } catch {
            // A stale graph after a device change fails to start; rebuild once.
            rebuild(reason: "engine start failed: \(error.localizedDescription)")
            try prepare()
            try engine.start()
        }
    }

    func pause() {
        if engine.isRunning { engine.pause() }
        // Wait for any conversion already executing, including its PCM handoff.
        // Later callbacks belong beyond this explicit boundary and are ignored.
        conversionLock.withLock {
            guard acceptingAudio else { return }
            acceptingAudio = false
            flushConverterTail()
            converter?.reset()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
    }

    /// Mark the graph stale, for example after sleep. The next start rebuilds it.
    func markNeedsRebuild() {
        needsRebuild = true
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
            source: currentDeviceName,
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
    /// No-op when the resolved device is unchanged: reinstalling the tap and
    /// re-priming the converter every toggle risks dropping leading frames.
    /// A preferred device that is no longer connected falls back to the default.
    func applyPreferredDevice(uniqueID: String) {
        let normalized = AudioDeviceList.normalizedPreference(uniqueID)
        let resolved = resolveDevice(preference: normalized)
        if tapInstalled, !needsRebuild, normalized == lastDevicePreference, resolved == currentDeviceID {
            return
        }
        lastDevicePreference = normalized
        rebuild(reason: "input device \(AudioDeviceList.name(of: resolved) ?? "default")", deviceID: resolved)
    }

    private func resolveDevice(preference: String) -> AudioDeviceID {
        if preference.isEmpty {
            return AudioDeviceList.defaultInputDeviceID()
        }
        let devices = AudioDeviceList.inputDevices()
        if let match = devices.first(where: { $0.uniqueID == preference }) ?? devices.first(where: { $0.name == preference }),
           match.audioDeviceID != 0
        {
            return match.audioDeviceID
        }
        AppLog.line("Preferred input \(preference) is not connected; using the system default.")
        return AudioDeviceList.defaultInputDeviceID()
    }

    /// Tear down the tap and converter and rebuild the graph for `deviceID`,
    /// restarting capture when it was running.
    private func rebuild(reason: String, deviceID: AudioDeviceID? = nil) {
        let wasCapturing = conversionLock.withLock { acceptingAudio }
        if engine.isRunning { engine.stop() }
        resetTap()
        engine.reset()
        let target = deviceID ?? resolveDevice(preference: lastDevicePreference ?? AudioDeviceList.systemDefaultPreference)
        if target != 0 {
            setInputDevice(target)
        }
        currentDeviceID = target
        needsRebuild = false
        AppLog.line("Audio input rebuilt (\(reason)); device=\(AudioDeviceList.name(of: target) ?? "unknown") capturing=\(wasCapturing)")
        guard wasCapturing else { return }
        do {
            try prepare()
            try engine.start()
        } catch {
            AppLog.line("Audio input restart failed after rebuild: \(error.localizedDescription)")
        }
    }

    private func handleConfigurationChange(reason: String) {
        let capturing = conversionLock.withLock { acceptingAudio }
        if capturing {
            rebuild(reason: reason)
        } else {
            needsRebuild = true
            AppLog.line("Audio input marked for rebuild (\(reason)).")
        }
    }

    /// Core Audio listeners for the system default input and the device list.
    private func installDeviceListenersIfNeeded() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, DispatchQueue.main) { [weak self] _, _ in
            guard let self, (self.lastDevicePreference ?? "").isEmpty else { return }
            self.handleConfigurationChange(reason: "system default input changed")
        }
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main) { [weak self] _, _ in
            guard let self else { return }
            let preference = self.lastDevicePreference ?? ""
            if self.resolveDevice(preference: preference) != self.currentDeviceID {
                self.handleConfigurationChange(reason: "input devices changed")
            }
        }
    }

    private func resetTap() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        conversionLock.withLock {
            converter = nil
        }
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

    private func convert(buffer: AVAudioPCMBuffer) {
        conversionLock.lock()
        defer { conversionLock.unlock() }
        guard acceptingAudio, let outputFormat else { return }
        // The input format can change under a running tap (device switch, sample
        // rate change). Follow the buffer, never a cached format.
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return }
        let estimatedFrames = ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 8
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
        deliver(Data(bytes: samples, count: Int(converted.frameLength) * MemoryLayout<Int16>.size))
    }

    /// Drain resampler history as well as the application's PCM chunker.
    /// Called with conversionLock held, after the input engine has paused.
    private func flushConverterTail() {
        guard let converter, let outputFormat else { return }
        for _ in 0..<8 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024) else { return }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] {
                deliver(Data(bytes: samples, count: Int(buffer.frameLength) * 2))
            }
            if status == .endOfStream || status == .error || buffer.frameLength == 0 { return }
        }
    }

    private func deliver(_ data: Data) {
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

    /// Core Audio display name of a device.
    static func name(of deviceID: AudioDeviceID) -> String? {
        guard deviceID != 0 else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
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
