import Foundation

/// A dictation's captured PCM16 16 kHz mono audio plus simple speech statistics.
/// Kept for the whole session so a Live failure, reconnect, or empty result can
/// be recovered by transcribing the audio itself.
public struct RecordedAudio: Sendable, Equatable {
    public var pcm: Data
    /// Duration of 40 ms frames whose energy crossed the speech threshold.
    public var voicedMs: Int
    /// Highest per-frame RMS, 0...1. Near zero means the input delivered silence.
    public var peakRms: Double
    /// The recorder hit its cap; later audio was not kept.
    public var truncated: Bool

    public init(pcm: Data, voicedMs: Int? = nil, peakRms: Double? = nil, truncated: Bool = false) {
        self.pcm = pcm
        let stats = (voicedMs == nil || peakRms == nil) ? audioStatistics(pcm) : (0, 0)
        self.voicedMs = voicedMs ?? stats.0
        self.peakRms = peakRms ?? stats.1
        self.truncated = truncated
    }

    public static let empty = RecordedAudio(pcm: Data(), voicedMs: 0, peakRms: 0)

    public var durationMs: Int { pcm.count / PCM_BYTES_PER_MILLISECOND }
    public var isEmpty: Bool { pcm.isEmpty }

    /// RIFF/WAVE container for the PCM, as accepted by Gemini inline audio.
    public func wav() -> Data {
        let sampleRate = UInt32(AUDIO_CONTRACT.sampleRate)
        let channels = UInt16(AUDIO_CONTRACT.channels)
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(pcm.count)
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(channels)
        append(sampleRate)
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        header.append(contentsOf: Array("data".utf8))
        append(dataSize)
        return header + pcm
    }

    /// Splits audio into pieces of at most `maximumMs`, cutting each at the
    /// quietest 40 ms frame in the final `searchWindowMs` before the limit so a
    /// cut rarely lands inside a word.
    public func split(maximumMs: Int, searchWindowMs: Int = 10_000) -> [RecordedAudio] {
        let frameBytes = PCM_CHUNK_BYTES
        let maximumBytes = max(frameBytes, (maximumMs * PCM_BYTES_PER_MILLISECOND) / frameBytes * frameBytes)
        guard pcm.count > maximumBytes else { return [self] }
        let windowBytes = min(maximumBytes / 2, (searchWindowMs * PCM_BYTES_PER_MILLISECOND) / frameBytes * frameBytes)
        var pieces: [RecordedAudio] = []
        var start = 0
        while pcm.count - start > maximumBytes {
            let limit = start + maximumBytes
            var cut = limit
            var quietest = Double.greatestFiniteMagnitude
            var offset = limit - frameBytes
            while offset >= limit - windowBytes {
                let rms = pcmRootMeanSquare(pcm.subdata(in: offset..<(offset + frameBytes)))
                if rms < quietest {
                    quietest = rms
                    cut = offset + frameBytes
                }
                offset -= frameBytes
            }
            pieces.append(RecordedAudio(pcm: pcm.subdata(in: start..<cut)))
            start = cut
        }
        pieces.append(RecordedAudio(pcm: pcm.subdata(in: start..<pcm.count)))
        return pieces
    }
}

/// (voicedMs, peakRms) over 40 ms frames.
func audioStatistics(_ pcm: Data) -> (Int, Double) {
    var voiced = 0
    var peak = 0.0
    var offset = 0
    while offset < pcm.count {
        let end = min(pcm.count, offset + PCM_CHUNK_BYTES)
        let frame = pcm.subdata(in: offset..<end)
        let rms = pcmRootMeanSquare(frame)
        peak = max(peak, rms)
        if rms >= PCM_VOICED_RMS_THRESHOLD { voiced += frame.count / PCM_BYTES_PER_MILLISECOND }
        offset = end
    }
    return (voiced, peak)
}

/// Thread-safe recorder for one dictation. Caps memory at `maximumMs`
/// (20 minutes is about 38 MB) and marks the snapshot truncated past that.
public final class SessionAudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var pcm = Data()
    private var voicedMs = 0
    private var peakRms = 0.0
    private var truncated = false

    public init(maximumMs: Int = 20 * 60 * 1000) {
        maximumBytes = maximumMs * PCM_BYTES_PER_MILLISECOND
    }

    /// Appends a chunk and returns its RMS so callers need not compute it twice.
    @discardableResult
    public func append(_ chunk: Data) -> Double {
        let rms = pcmRootMeanSquare(chunk)
        lock.withLock {
            guard pcm.count + chunk.count <= maximumBytes else {
                truncated = true
                return
            }
            pcm.append(chunk)
            peakRms = max(peakRms, rms)
            if rms >= PCM_VOICED_RMS_THRESHOLD {
                voicedMs += chunk.count / PCM_BYTES_PER_MILLISECOND
            }
        }
        return rms
    }

    public func snapshot() -> RecordedAudio {
        lock.withLock {
            RecordedAudio(pcm: pcm, voicedMs: voicedMs, peakRms: peakRms, truncated: truncated)
        }
    }
}
