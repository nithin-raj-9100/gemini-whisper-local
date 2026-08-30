import { AUDIO_CONTRACT } from "./types.ts";

export const PCM_BYTES_PER_FRAME = 2;
export const PCM_CHUNK_BYTES =
  (AUDIO_CONTRACT.sampleRate * AUDIO_CONTRACT.chunkMilliseconds * PCM_BYTES_PER_FRAME) / 1000;

export function validatePcmChunk(chunk: Uint8Array): void {
  if (chunk.byteLength === 0) throw new Error("Audio chunks cannot be empty.");
  if (chunk.byteLength % PCM_BYTES_PER_FRAME !== 0) {
    throw new Error("PCM16 audio chunks must contain an even number of bytes.");
  }
}

export class PcmChunker {
  #pending = new Uint8Array(0);

  push(input: Uint8Array): Uint8Array[] {
    if (input.byteLength === 0) return [];

    const joined = new Uint8Array(this.#pending.byteLength + input.byteLength);
    joined.set(this.#pending);
    joined.set(input, this.#pending.byteLength);

    const output: Uint8Array[] = [];
    let offset = 0;
    while (joined.byteLength - offset >= PCM_CHUNK_BYTES) {
      output.push(joined.slice(offset, offset + PCM_CHUNK_BYTES));
      offset += PCM_CHUNK_BYTES;
    }
    this.#pending = joined.slice(offset);
    return output;
  }

  flush(): Uint8Array | undefined {
    if (this.#pending.byteLength === 0) return undefined;
    const usableBytes = this.#pending.byteLength - (this.#pending.byteLength % PCM_BYTES_PER_FRAME);
    const final = usableBytes > 0 ? this.#pending.slice(0, usableBytes) : undefined;
    this.#pending = new Uint8Array(0);
    return final;
  }
}

