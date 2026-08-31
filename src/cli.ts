#!/usr/bin/env bun
import { LocalTranscriptionClient } from "./client.ts";
import { createDaemon } from "./server.ts";
import { ensureLocalAuthToken } from "./local-auth.ts";
import { TerminalPreview } from "./terminal-preview.ts";
import type { ServerEvent, TranscriptionConfig } from "./types.ts";

// Bounded buffer for audio captured before the local daemon and Gemini are ready.
const MAX_QUEUED_AUDIO_BYTES = 16000 * 2 * 10;

const command = Bun.argv[2] ?? "help";
const flags = parseFlags(Bun.argv.slice(3));
const systemMode = flags.has("system");
const capturedFinals: string[] = [];
let capturedPolished = "";
let capturedPolishLatencyMs = 0;
let capturedSpeculativePolish = false;
const terminalPreview = new TerminalPreview(
  (text) => process.stdout.write(text),
  Boolean(process.stdout.isTTY),
  Math.max(80, (process.stdout.columns ?? 80) * 3),
  process.stdout.columns ?? 80,
);

switch (command) {
  case "serve":
    createDaemon({
      authToken: await ensureLocalAuthToken(),
      hostname: Bun.env.GEMINI_WHISPER_HOST,
      port: optionalNumber(Bun.env.GEMINI_WHISPER_PORT),
    });
    break;
  case "serve:sdk": {
    const { createSdkDaemon } = await import("./sdk-server.ts");
    createSdkDaemon({ authToken: await ensureLocalAuthToken() });
    break;
  }
  case "mic":
    await transcribeMicrophone(flags);
    break;
  case "file":
    await transcribeFile(flags);
    break;
  case "devices":
    await listDevices();
    break;
  default:
    printHelp();
}

async function transcribeMicrophone(flags: Map<string, string | true>): Promise<void> {
  const audioRelayPort = numberFlag(flags, "audio-relay-port");
  if (audioRelayPort !== undefined) return transcribeMacAudioRelay(flags, audioRelayPort);
  const audioHelperApp = stringFlag(flags, "audio-helper-app");
  if (audioHelperApp) return transcribeMacAudioHelper(flags, audioHelperApp);
  ensureFfmpeg();
  const device = stringFlag(flags, "device") ?? Bun.env.GEMINI_WHISPER_AUDIO_DEVICE ?? ":0";
  const inputArgs = microphoneInputArgs(device);
  if (!systemMode) console.log("Connecting to the local daemon…");
  const ffmpeg = Bun.spawn(
    ["ffmpeg", "-hide_banner", "-loglevel", "error", ...inputArgs, ...pcmOutputArgs()],
    { stdout: "pipe", stderr: "pipe", stdin: "ignore" },
  );
  const stderr = new Response(ffmpeg.stderr).text();
  let client: LocalTranscriptionClient;
  try {
    client = await connectClient(flags);
  } catch (error) {
    ffmpeg.kill("SIGTERM");
    await ffmpeg.exited;
    const ffmpegError = (await stderr).trim();
    if (ffmpegError) console.error(ffmpegError);
    throw error;
  }
  if (!systemMode) console.log("Listening. Press Enter to stop; Ctrl+C cancels.");

  const audio = { bytes: 0, samples: 0, sumSquares: 0, peak: 0 };
  const stopReading = streamProcessAudio(ffmpeg.stdout, client, audio);
  const inputReader = Bun.stdin.stream().getReader();
  const stoppedBy = await Promise.race([
    inputReader.read().then(() => "user" as const),
    stopReading.then(() => "stream" as const),
  ]);
  if (stoppedBy === "stream") await inputReader.cancel();
  inputReader.releaseLock();
  // Manual VAD bypasses Gemini's server-side prefix/silence buffering. Keep a
  // short tail after button release so the final phoneme and end-of-speech
  // silence reach Gemini before activityEnd.
  if (stoppedBy === "user" && !flags.has("automatic-vad") && !client.closed) {
    await Bun.sleep(500);
  }
  ffmpeg.kill("SIGTERM");
  const exitCode = await ffmpeg.exited;
  await stopReading;
  const ffmpegError = await stderr;
  if (systemMode) {
    const rms = audio.samples > 0 ? Math.round(Math.sqrt(audio.sumSquares / audio.samples)) : 0;
    console.error(
      `Captured ${audio.bytes} PCM bytes from microphone ${device} (RMS ${rms}, peak ${audio.peak}).`,
    );
  }
  if (exitCode !== 0 && ffmpegError.trim()) console.error(ffmpegError.trim());
  if (stoppedBy === "user" && !client.closed) await client.finish();
  const clientError = client.error;
  client.close();
  if (clientError) {
    if (!capturedPolished && capturedFinals.length === 0) throw clientError;
    console.error(`Warning: ${clientError.message}; using captured transcript.`);
  }
  if (systemMode) {
    const text = capturedPolished || capturedFinals.join("\n").trim();
    console.log(
      JSON.stringify({
        text,
        polished: Boolean(capturedPolished),
        polishLatencyMs: capturedPolishLatencyMs,
        speculative: capturedSpeculativePolish,
      }),
    );
  }
}

async function transcribeMacAudioRelay(
  flags: Map<string, string | true>,
  port: number,
): Promise<void> {
  const metrics = { bytes: 0, samples: 0, sumSquares: 0, peak: 0 };
  const queued: Uint8Array[] = [];
  let queuedBytes = 0;
  let client: LocalTranscriptionClient | undefined;
  const clientPromise = connectClient(flags);
  const audioSocket = await Bun.connect({
    hostname: "127.0.0.1",
    port,
    socket: {
      data(_socket, data) {
        updateAudioMetrics(metrics, data);
        if (client) client.sendAudio(data);
        else if (queuedBytes < MAX_QUEUED_AUDIO_BYTES) {
          queued.push(data.slice());
          queuedBytes += data.byteLength;
        }
      },
      open() {},
      close() {},
      error(_socket, error) {
        console.error(`Persistent macOS audio relay failed: ${error.message}`);
      },
      connectError(_socket, error) {
        console.error(`Could not connect to persistent macOS audio relay: ${error.message}`);
      },
    },
  });

  try {
    client = await clientPromise;
    for (const chunk of queued) {
      if (!client.sendAudio(chunk)) break;
    }
    queued.length = 0;
    queuedBytes = 0;

    const inputReader = Bun.stdin.stream().getReader();
    await inputReader.read();
    inputReader.releaseLock();
    // Drain in-flight audio from the relay before finalizing so the final
    // phonemes reach Gemini. Tunable via GEMINI_WHISPER_DRAIN_MS.
    await Bun.sleep(Number(Bun.env.GEMINI_WHISPER_DRAIN_MS ?? 400));
    audioSocket.end();
    if (!client.closed) await client.finish();
    const clientError = client.error;
    client.close();
    if (clientError) {
      if (!capturedPolished && capturedFinals.length === 0) throw clientError;
      console.error(`Warning: ${clientError.message}; using captured transcript.`);
    }

    if (systemMode) {
      const rms = metrics.samples > 0 ? Math.round(Math.sqrt(metrics.sumSquares / metrics.samples)) : 0;
      console.error(
        `Captured ${metrics.bytes} PCM bytes from persistent Gemini Whisper Audio (RMS ${rms}, peak ${metrics.peak}).`,
      );
      const text = capturedPolished || capturedFinals.join("\n").trim();
      console.log(
        JSON.stringify({
          text,
          polished: Boolean(capturedPolished),
          polishLatencyMs: capturedPolishLatencyMs,
          speculative: capturedSpeculativePolish,
        }),
      );
    }
  } finally {
    audioSocket.end();
    client?.close();
  }
}

async function transcribeMacAudioHelper(
  flags: Map<string, string | true>,
  appPath: string,
): Promise<void> {
  if (!(await Bun.file(`${appPath}/Contents/MacOS/GeminiWhisperAudio`).exists())) {
    throw new Error(`macOS audio helper is not built: ${appPath}`);
  }

  const metrics = { bytes: 0, samples: 0, sumSquares: 0, peak: 0 };
  const queued: Uint8Array[] = [];
  let client: LocalTranscriptionClient | undefined;
  let captureSocket: Bun.Socket<undefined> | undefined;
  const receiver = Bun.listen({
    hostname: "127.0.0.1",
    port: 0,
    socket: {
      data(socket, data) {
        updateAudioMetrics(metrics, data);
        if (client) client.sendAudio(data);
        else queued.push(data.slice());
      },
      open(socket) {
        captureSocket = socket;
      },
      close() {},
      error(_socket, error) {
        console.error(`macOS audio helper socket failed: ${error.message}`);
      },
    },
  });

  const launcher = Bun.spawn(
    ["/usr/bin/open", "-n", "-g", appPath, "--args", "--port", String(receiver.port)],
    { stdin: "ignore", stdout: "ignore", stderr: "pipe" },
  );
  const launchError = new Response(launcher.stderr).text();

  try {
    client = await connectClient(flags);
    for (const chunk of queued) {
      if (!client.sendAudio(chunk)) break;
    }
    queued.length = 0;

    const inputReader = Bun.stdin.stream().getReader();
    await inputReader.read();
    inputReader.releaseLock();
    if (!flags.has("automatic-vad") && !client.closed) await Bun.sleep(500);
    captureSocket?.end();
    receiver.stop(true);

    if (!client.closed) await client.finish();
    const clientError = client.error;
    client.close();
    if (clientError) throw clientError;

    if (systemMode) {
      const rms = metrics.samples > 0 ? Math.round(Math.sqrt(metrics.sumSquares / metrics.samples)) : 0;
      console.error(
        `Captured ${metrics.bytes} PCM bytes from Gemini Whisper Audio (RMS ${rms}, peak ${metrics.peak}).`,
      );
      const text = capturedPolished || capturedFinals.join("\n").trim();
      console.log(
        JSON.stringify({
          text,
          polished: Boolean(capturedPolished),
          polishLatencyMs: capturedPolishLatencyMs,
          speculative: capturedSpeculativePolish,
        }),
      );
    }
  } finally {
    captureSocket?.end();
    receiver.stop(true);
    if (launcher.exitCode === null) launcher.kill("SIGTERM");
    await launcher.exited;
    const error = (await launchError).trim();
    if (error) console.error(error);
    client?.close();
  }
}

async function transcribeFile(flags: Map<string, string | true>): Promise<void> {
  ensureFfmpeg();
  const path = Bun.argv[3];
  if (!path || path.startsWith("--")) throw new Error("Usage: bun run file <audio-path> [options]");
  if (!(await Bun.file(path).exists())) throw new Error(`Audio file does not exist: ${path}`);

  const client = await connectClient(flags);
  const ffmpeg = Bun.spawn(
    ["ffmpeg", "-hide_banner", "-loglevel", "error", "-re", "-i", path, ...pcmOutputArgs()],
    { stdout: "pipe", stderr: "pipe", stdin: "ignore" },
  );
  const stderr = new Response(ffmpeg.stderr).text();
  const streamedAll = await streamProcessAudio(ffmpeg.stdout, client);
  if (!streamedAll) ffmpeg.kill("SIGTERM");
  const exitCode = await ffmpeg.exited;
  const ffmpegError = await stderr;
  if (exitCode !== 0 && streamedAll) {
    throw new Error(ffmpegError.trim() || `ffmpeg exited with code ${exitCode}.`);
  }
  if (!client.closed) await client.finish();
  client.close();
}

async function connectClient(flags: Map<string, string | true>): Promise<LocalTranscriptionClient> {
  const host = Bun.env.GEMINI_WHISPER_HOST ?? "127.0.0.1";
  const port = Bun.env.GEMINI_WHISPER_PORT ?? "8765";
  const vocabulary = stringFlag(flags, "vocabulary")
    ?.split(",")
    .map((term) => term.trim())
    .filter(Boolean);
  const config: Partial<TranscriptionConfig> = {
    mode: flags.has("verbatim") ? "verbatim" : "smart",
    polish: !flags.has("verbatim") && !flags.has("no-polish"),
    vad: flags.has("automatic-vad") ? "hybrid" : "manual",
    languageCodes: stringFlag(flags, "language") ? [stringFlag(flags, "language")!] : [],
    customVocabulary: vocabulary ?? [],
    vadPrefixPaddingMs: numberFlag(flags, "prefix-padding-ms") ?? 500,
    vadSilenceDurationMs: numberFlag(flags, "silence-ms") ?? 1500,
  };

  let failed: Error | undefined;
  const client = new LocalTranscriptionClient({
    url: `ws://${host}:${port}/v1/transcribe`,
    authToken: await ensureLocalAuthToken(),
    config,
    onEvent(event) {
      printEvent(event);
      if (event.type === "error") failed = new Error(`${event.code}: ${event.message}`);
    },
  });
  await Promise.race([
    client.connect(),
    Bun.sleep(20_000).then(() => {
      throw new Error("Timed out waiting for the local daemon and Gemini.");
    }),
  ]);
  if (failed) throw failed;
  return client;
}

async function streamProcessAudio(
  stream: ReadableStream<Uint8Array>,
  client: LocalTranscriptionClient,
  metrics?: { bytes: number; samples: number; sumSquares: number; peak: number },
): Promise<boolean> {
  const reader = stream.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) return true;
      if (value && metrics) updateAudioMetrics(metrics, value);
      if (value && !client.sendAudio(value)) return false;
    }
  } finally {
    reader.releaseLock();
  }
}

function updateAudioMetrics(
  metrics: { bytes: number; samples: number; sumSquares: number; peak: number },
  audio: Uint8Array,
): void {
  metrics.bytes += audio.byteLength;
  const view = new DataView(audio.buffer, audio.byteOffset, audio.byteLength);
  const usableBytes = audio.byteLength - (audio.byteLength % 2);
  for (let offset = 0; offset < usableBytes; offset += 2) {
    const sample = view.getInt16(offset, true);
    const magnitude = Math.abs(sample);
    metrics.samples++;
    metrics.sumSquares += sample * sample;
    if (magnitude > metrics.peak) metrics.peak = magnitude;
  }
}

function printEvent(event: ServerEvent): void {
  if (systemMode) {
    if (event.type === "interim") {
      const cumulative = [...capturedFinals, event.text].filter(Boolean).join(" ").trim();
      console.log(JSON.stringify({ type: "interim", text: cumulative }));
    } else if (event.type === "final") {
      capturedFinals.push(event.text);
      const cumulative = capturedFinals.filter(Boolean).join(" ").trim();
      console.log(JSON.stringify({ type: "final", text: cumulative }));
    } else if (event.type === "polished") {
      capturedPolished = event.text;
      capturedPolishLatencyMs = event.latencyMs;
      capturedSpeculativePolish = event.speculative === true;
      console.log(JSON.stringify({ type: "polished", text: event.text }));
    } else if (event.type === "warning") {
      console.error(`${event.code}: ${event.message}`);
    } else if (event.type === "error") {
      console.error(`${event.code}: ${event.message}`);
    }
    return;
  }
  switch (event.type) {
    case "interim":
      terminalPreview.update(event.text);
      break;
    case "final":
      terminalPreview.commit(event.text);
      break;
    case "polished":
      terminalPreview.clear();
      console.log(`\nPolished (${event.latencyMs} ms):\n${event.text}`);
      break;
    case "warning":
      terminalPreview.clear();
      console.error(`\n${event.code}: ${event.message}`);
      break;
    case "error":
      terminalPreview.clear();
      console.error(`\n${event.code}: ${event.message}`);
      break;
  }
}

function microphoneInputArgs(device: string): string[] {
  if (process.platform === "darwin") return ["-f", "avfoundation", "-i", device];
  if (process.platform === "linux") return ["-f", "pulse", "-i", device === ":0" ? "default" : device];
  if (process.platform === "win32") return ["-f", "dshow", "-i", `audio=${device}`];
  throw new Error(`Microphone capture is not configured for ${process.platform}.`);
}

function pcmOutputArgs(): string[] {
  return ["-vn", "-ac", "1", "-ar", "16000", "-acodec", "pcm_s16le", "-f", "s16le", "pipe:1"];
}

async function listDevices(): Promise<void> {
  ensureFfmpeg();
  const args =
    process.platform === "darwin"
      ? ["ffmpeg", "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""]
      : ["ffmpeg", "-hide_banner", "-sources", "true", "-f", process.platform === "win32" ? "dshow" : "pulse"];
  const processHandle = Bun.spawn(args, { stdout: "inherit", stderr: "inherit" });
  await processHandle.exited;
}

function ensureFfmpeg(): void {
  if (!Bun.which("ffmpeg")) throw new Error("ffmpeg is required for microphone and file input.");
}

function parseFlags(args: string[]): Map<string, string | true> {
  const flags = new Map<string, string | true>();
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (!arg?.startsWith("--")) continue;
    const [rawName, inlineValue] = arg.slice(2).split("=", 2);
    if (!rawName) continue;
    const next = args[index + 1];
    if (inlineValue !== undefined) flags.set(rawName, inlineValue);
    else if (next && !next.startsWith("--")) {
      flags.set(rawName, next);
      index++;
    } else flags.set(rawName, true);
  }
  return flags;
}

function stringFlag(flags: Map<string, string | true>, name: string): string | undefined {
  const value = flags.get(name);
  return typeof value === "string" ? value : undefined;
}

function optionalNumber(value: string | undefined): number | undefined {
  if (value === undefined || value === "") return undefined;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 65535) {
    throw new Error(`Invalid port: ${value}`);
  }
  return parsed;
}

function numberFlag(flags: Map<string, string | true>, name: string): number | undefined {
  const value = stringFlag(flags, name);
  if (value === undefined) return undefined;
  const parsed = Number(value);
  if (!Number.isInteger(parsed)) throw new Error(`--${name} must be an integer.`);
  return parsed;
}

function printHelp(): void {
  console.log(`gemini-whisper-local

Commands:
  bun run serve                         Start the localhost daemon
  bun run serve:sdk                     Start the Google SDK daemon
  bun run mic [options]                 Stream the microphone until Enter
  bun run file <path> [options]         Stream an audio file in real time
  bun run devices                       List ffmpeg capture devices

Options:
  --device <id>                         ffmpeg microphone device (default :0 on macOS)
  --language <BCP-47>                   Hint a language, for example en-IN
  --vocabulary <term,term>              Bias domain-specific words
  --verbatim                            Preserve fillers and false starts
  --no-polish                           Skip the Flash-Lite cleanup pass
  --manual-vad                          Use explicit activity boundaries (default)
  --automatic-vad                       Split turns automatically at pauses
  --prefix-padding-ms <0-2000>          Automatic-VAD speech onset padding (default 300)
  --silence-ms <100-5000>               Automatic-VAD pause threshold (default 1000)
  --system                              Emit one machine-readable final result

Environment:
  GEMINI_API_KEY                        Required by the daemon
  GEMINI_WHISPER_HOST                   Default 127.0.0.1
  GEMINI_WHISPER_PORT                   Default 8765
  GEMINI_WHISPER_AUDIO_DEVICE           Default :0 on macOS`);
}
