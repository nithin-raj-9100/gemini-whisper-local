import Foundation
@testable import GeminiWhisperCore
import Testing

@Suite("PcmChunker")
struct AudioTests {
    @Test func emitsExact100msPCMChunks() {
        let chunker = PcmChunker()
        #expect(chunker.push(Data(count: 1000)).isEmpty)
        let chunks = chunker.push(Data(count: PCM_CHUNK_BYTES * 2))
        #expect(chunks.count == 2)
        #expect(chunks[0].count == PCM_CHUNK_BYTES)
        #expect(chunks[1].count == PCM_CHUNK_BYTES)
        #expect(chunker.flush()?.count == 1000)
    }

    @Test func dropsATrailingHalfFrameOnFlush() {
        let chunker = PcmChunker()
        _ = chunker.push(Data(count: 3))
        #expect(chunker.flush()?.count == 2)
    }

    @Test func rejectsEmptyOrOddBytePCM() {
        #expect(throws: TranscriptionError.self) {
            try validatePcmChunk(Data())
        }
        #expect(throws: TranscriptionError.self) {
            try validatePcmChunk(Data(count: 3))
        }
        try! validatePcmChunk(Data(count: 2))
    }
}
