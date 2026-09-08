import Foundation

/// Conservative energy-based pause hint for the opt-in hybrid mode.
/// This never filters PCM: even audio classified as quiet is sent to Gemini.
public struct LocalSpeechEndpoint {
    private var voicedSamples = 0
    private var quietSamples = 0
    private let silenceSamples: Int

    public init(silenceMilliseconds: Int = 600) {
        silenceSamples = max(300, silenceMilliseconds) * 16
    }

    public mutating func accept(_ pcm: Data) -> Bool {
        let bytes = [UInt8](pcm)
        guard bytes.count >= 2 else { return false }
        var energy = 0.0
        for index in stride(from: 0, to: bytes.count - 1, by: 2) {
            let sample = Double(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)) / 32768
            energy += sample * sample
        }
        let samples = bytes.count / 2
        if sqrt(energy / Double(samples)) >= 0.002 {
            voicedSamples += samples
            quietSamples = 0
        } else if voicedSamples >= 1600 {
            quietSamples += samples
        }
        guard quietSamples >= silenceSamples else { return false }
        voicedSamples = 0
        quietSamples = 0
        return true
    }
}
