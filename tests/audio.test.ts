import { describe, expect, test } from "bun:test";
import { PCM_CHUNK_BYTES, PcmChunker, validatePcmChunk } from "../src/audio.ts";

describe("PcmChunker", () => {
  test("emits exact 100 ms PCM chunks", () => {
    const chunker = new PcmChunker();
    expect(chunker.push(new Uint8Array(1000))).toHaveLength(0);
    const chunks = chunker.push(new Uint8Array(PCM_CHUNK_BYTES * 2));
    expect(chunks).toHaveLength(2);
    expect(chunks[0]?.byteLength).toBe(PCM_CHUNK_BYTES);
    expect(chunks[1]?.byteLength).toBe(PCM_CHUNK_BYTES);
    expect(chunker.flush()?.byteLength).toBe(1000);
  });

  test("drops a trailing half-frame on flush", () => {
    const chunker = new PcmChunker();
    chunker.push(new Uint8Array(3));
    expect(chunker.flush()?.byteLength).toBe(2);
  });
});

describe("validatePcmChunk", () => {
  test("rejects empty or odd-byte PCM", () => {
    expect(() => validatePcmChunk(new Uint8Array())).toThrow();
    expect(() => validatePcmChunk(new Uint8Array(3))).toThrow();
    expect(() => validatePcmChunk(new Uint8Array(2))).not.toThrow();
  });
});

