#!/usr/bin/env bun
import { PCM_CHUNK_BYTES } from "../src/audio.ts";
import type { ServerEvent, TranscriptionConfig } from "../src/types.ts";

const audioPath = Bun.argv[2];
if (!audioPath) {
  throw new Error(
    "Usage: bun run benchmark:latency <16kHz-mono-PCM.wav> [trials] [interval-ms]",
  );
}
const trials = Math.max(1, Number(Bun.argv[3] ?? 20));
const intervalMs = Math.max(0, Number(Bun.argv[4] ?? 20_000));
const wav = new Uint8Array(await Bun.file(audioPath).arrayBuffer());
const pcm = extractPcm16Mono16k(wav);
const host = Bun.env.GEMINI_WHISPER_HOST ?? "127.0.0.1";
const port = Bun.env.GEMINI_WHISPER_PORT ?? "8765";
const language = Bun.env.GEMINI_WHISPER_LANGUAGE ?? "en-IN";
const config: Partial<TranscriptionConfig> = {
  mode: "smart",
  vad: "hybrid",
  languageCodes: language ? [language] : [],
  customVocabulary: [],
  vadPrefixPaddingMs: 300,
  vadSilenceDurationMs: 1000,
};

console.log(`Warming with ${Math.round(pcm.byteLength / 32) / 1000}s of audio…`);
await runTrial(pcm, config);
if (intervalMs > 0) await Bun.sleep(intervalMs);

const results: Array<{
  totalMs: number;
  polishMs: number;
  speculative: boolean;
  warnings: string[];
}> = [];
for (let index = 0; index < trials; index++) {
  const result = await runTrial(pcm, config);
  results.push(result);
  console.log(
    `${String(index + 1).padStart(2, "0")}/${trials}: ${result.totalMs} ms total, ` +
      `${result.polishMs || "NO"} ms Flash-Lite` +
      (result.speculative ? " [overlapped]" : " [after final]") +
      (result.warnings.length ? ` [${result.warnings.join("; ")}]` : ""),
  );
  if (index + 1 < trials && intervalMs > 0) await Bun.sleep(intervalMs);
}

const successful = results.filter((result) => result.polishMs > 0);
const totals = successful.map((result) => result.totalMs).sort((a, b) => a - b);
const polish = successful.map((result) => result.polishMs).sort((a, b) => a - b);
console.log("\nStop-to-complete benchmark");
console.log(`trials: ${trials}`);
console.log(`polished successes: ${successful.length}/${trials}`);
console.log(`speculative reuse: ${successful.filter((result) => result.speculative).length}/${successful.length}`);
if (successful.length === 0) throw new Error("No trial returned polished text.");
console.log(`median: ${percentile(totals, 0.5)} ms`);
console.log(`p95: ${percentile(totals, 0.95)} ms`);
console.log(`min/max: ${totals[0]} / ${totals.at(-1)} ms`);
console.log(`Flash-Lite median/p95: ${percentile(polish, 0.5)} / ${percentile(polish, 0.95)} ms`);

async function runTrial(
  audio: Uint8Array,
  transcriptionConfig: Partial<TranscriptionConfig>,
): Promise<{ totalMs: number; polishMs: number; speculative: boolean; warnings: string[] }> {
  let readyResolve!: () => void;
  let completeResolve!: () => void;
  let failureReject!: (error: Error) => void;
  const ready = new Promise<void>((resolve) => (readyResolve = resolve));
  const complete = new Promise<void>((resolve, reject) => {
    completeResolve = resolve;
    failureReject = reject;
  });
  let polishMs = 0;
  let speculative = false;
  const warnings: string[] = [];
  const socket = new WebSocket(`ws://${host}:${port}/v1/transcribe`);
  socket.binaryType = "arraybuffer";
  socket.addEventListener("open", () => {
    socket.send(JSON.stringify({ type: "start", config: transcriptionConfig }));
  });
  socket.addEventListener("message", (message) => {
    if (typeof message.data !== "string") return;
    const event = JSON.parse(message.data) as ServerEvent;
    if (event.type === "ready") readyResolve();
    if (event.type === "polished") {
      polishMs = event.latencyMs;
      speculative = event.speculative === true;
    }
    if (event.type === "warning") warnings.push(`${event.code}: ${event.message}`);
    if (event.type === "error") failureReject(new Error(`${event.code}: ${event.message}`));
    if (event.type === "complete") completeResolve();
  });
  socket.addEventListener("error", () => failureReject(new Error("Local benchmark socket failed.")));

  await Promise.race([ready, timeout(15_000, "Timed out connecting to Gemini Live.")]);
  for (let offset = 0; offset < audio.byteLength; offset += PCM_CHUNK_BYTES) {
    socket.send(audio.slice(offset, Math.min(audio.byteLength, offset + PCM_CHUNK_BYTES)));
    await Bun.sleep(100);
  }
  const stoppedAt = Bun.nanoseconds();
  socket.send(JSON.stringify({ type: "stop" }));
  await Promise.race([complete, timeout(10_000, "Timed out waiting for polished text.")]);
  const totalMs = Math.round((Bun.nanoseconds() - stoppedAt) / 1e6);
  socket.close();
  return { totalMs, polishMs, speculative, warnings };
}

function extractPcm16Mono16k(wavBytes: Uint8Array): Uint8Array {
  const view = new DataView(wavBytes.buffer, wavBytes.byteOffset, wavBytes.byteLength);
  if (textAt(wavBytes, 0, 4) !== "RIFF" || textAt(wavBytes, 8, 4) !== "WAVE") {
    throw new Error("Benchmark input must be a WAV file.");
  }
  let offset = 12;
  let validFormat = false;
  let data: Uint8Array | undefined;
  while (offset + 8 <= wavBytes.byteLength) {
    const id = textAt(wavBytes, offset, 4);
    const size = view.getUint32(offset + 4, true);
    const body = offset + 8;
    if (id === "fmt " && size >= 16) {
      validFormat =
        view.getUint16(body, true) === 1 &&
        view.getUint16(body + 2, true) === 1 &&
        view.getUint32(body + 4, true) === 16_000 &&
        view.getUint16(body + 14, true) === 16;
    }
    if (id === "data") data = wavBytes.slice(body, body + size);
    offset = body + size + (size % 2);
  }
  if (!validFormat || !data) throw new Error("WAV must be PCM16, mono, and 16 kHz.");
  return data;
}

function textAt(bytes: Uint8Array, offset: number, length: number): string {
  return new TextDecoder().decode(bytes.subarray(offset, offset + length));
}

function percentile(sorted: number[], fraction: number): number {
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)]!;
}

function timeout(milliseconds: number, message: string): Promise<never> {
  return Bun.sleep(milliseconds).then(() => {
    throw new Error(message);
  });
}
