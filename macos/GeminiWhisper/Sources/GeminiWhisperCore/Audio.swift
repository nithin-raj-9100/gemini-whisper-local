import Foundation

public let PCM_BYTES_PER_FRAME = 2
/// 16 kHz mono PCM16: 32 bytes per millisecond.
public let PCM_BYTES_PER_MILLISECOND = AUDIO_CONTRACT.sampleRate * PCM_BYTES_PER_FRAME / 1000
public let PCM_CHUNK_BYTES =
    (AUDIO_CONTRACT.sampleRate * AUDIO_CONTRACT.chunkMilliseconds * PCM_BYTES_PER_FRAME) / 1000

public func validatePcmChunk(_ chunk: Data) throws {
    if chunk.isEmpty {
        throw TranscriptionError("Audio chunks cannot be empty.")
    }
    if chunk.count % PCM_BYTES_PER_FRAME != 0 {
        throw TranscriptionError("PCM16 audio chunks must contain an even number of bytes.")
    }
}

/// Normalized RMS of a PCM16 little-endian buffer, 0...1.
public func pcmRootMeanSquare(_ pcm: Data) -> Double {
    let samples = pcm.count / 2
    guard samples > 0 else { return 0 }
    // Runs for every 40 ms frame in several places; read in place instead of
    // copying the frame into a temporary array.
    let energy = pcm.withUnsafeBytes { raw -> Double in
        var sum = 0.0
        for index in 0..<samples {
            let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
            sum += sample * sample
        }
        return sum
    }
    return (energy / Double(samples)).squareRoot()
}

/// Energy floor separating speech from room tone, shared by the stop-tail
/// shortcut and the hybrid endpointer so they never disagree about silence.
public let PCM_VOICED_RMS_THRESHOLD = 0.002

public final class PcmChunker {
    private var pending = Data()

    public init() {}

    public func push(_ input: Data) -> [Data] {
        if input.isEmpty { return [] }

        pending.append(input)
        var output: [Data] = []
        while pending.count >= PCM_CHUNK_BYTES {
            output.append(pending.prefix(PCM_CHUNK_BYTES))
            pending.removeFirst(PCM_CHUNK_BYTES)
        }
        return output
    }

    public func flush() -> Data? {
        if pending.isEmpty { return nil }
        let usableBytes = pending.count - (pending.count % PCM_BYTES_PER_FRAME)
        let final = usableBytes > 0 ? pending.prefix(usableBytes) : nil
        pending = Data()
        return final.map { Data($0) }
    }
}
