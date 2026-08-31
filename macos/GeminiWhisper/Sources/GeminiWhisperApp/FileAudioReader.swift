@preconcurrency import AVFoundation
import Foundation
import GeminiWhisperCore

/// Reads an audio file and yields 16 kHz Int16 mono PCM.
enum FileAudioReader {
    static let realtimeFrameBytes = PCM_CHUNK_BYTES
    static let realtimeFrameNanoseconds = UInt64(AUDIO_CONTRACT.chunkMilliseconds) * 1_000_000

    static func pcm16kMonoChunks(from url: URL) throws -> [Data] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw FileAudioError.converterFailed
        }

        let frameCapacity: AVAudioFrameCount = 4_096
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCapacity) else {
            throw FileAudioError.converterFailed
        }

        var chunks: [Data] = []
        while true {
            do {
                try file.read(into: inputBuffer)
            } catch {
                break
            }
            if inputBuffer.frameLength == 0 { break }

            let estimatedFrames = ceil(Double(inputBuffer.frameLength) * 16_000 / inputFormat.sampleRate) + 8
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(estimatedFrames)
            ) else { continue }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if status == .error { throw FileAudioError.conversion(conversionError?.localizedDescription) }
            guard converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { continue }
            chunks.append(Data(bytes: samples, count: Int(converted.frameLength) * MemoryLayout<Int16>.size))
        }
        if chunks.isEmpty {
            throw FileAudioError.emptyFile
        }
        return chunks
    }

    static func pcm16kMono(from url: URL) throws -> Data {
        let chunks = try pcm16kMonoChunks(from: url)
        var combined = Data()
        combined.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
        for chunk in chunks { combined.append(chunk) }
        return combined
    }

    /// Split concatenated PCM into ~100 ms / 3200-byte frames (last frame may be shorter).
    static func realtimeFrames(from pcm: Data) -> [Data] {
        guard !pcm.isEmpty else { return [] }
        var frames: [Data] = []
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + realtimeFrameBytes, pcm.count)
            frames.append(pcm.subdata(in: offset..<end))
            offset = end
        }
        return frames
    }

    enum FileAudioError: LocalizedError {
        case converterFailed
        case conversion(String?)
        case emptyFile

        var errorDescription: String? {
            switch self {
            case .converterFailed:
                return "Could not convert the audio file to 16 kHz PCM."
            case .conversion(let detail):
                return "Audio file conversion failed: \(detail ?? "unknown error")."
            case .emptyFile:
                return "The audio file produced no PCM samples."
            }
        }
    }
}
