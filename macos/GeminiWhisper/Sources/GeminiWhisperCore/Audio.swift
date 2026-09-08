import Foundation

public let PCM_BYTES_PER_FRAME = 2
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
    let bytes = [UInt8](pcm)
    guard bytes.count >= 2 else { return 0 }
    var energy = 0.0
    for index in stride(from: 0, to: bytes.count - 1, by: 2) {
        let sample = Double(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)) / 32768
        energy += sample * sample
    }
    return (energy / Double(bytes.count / 2)).squareRoot()
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
