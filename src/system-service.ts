import { createDaemon } from "./server.ts";
import { ensureLocalAuthToken, requestHasBearerToken } from "./local-auth.ts";
import { SlidingWindowRateLimiter } from "./rate-limit.ts";

const projectRoot = new URL("..", import.meta.url).pathname.replace(/\/$/, "");
const hostname = "127.0.0.1";
const hotkeyPort = Number(Bun.env.GEMINI_WHISPER_HOTKEY_PORT ?? 8766);
const transport = Bun.env.GEMINI_WHISPER_TRANSPORT === "sdk" ? "sdk" : "native";
const audioHelperApp = `${projectRoot}/macos/GeminiWhisperAudio.app`;
const systemLanguage = Bun.env.GEMINI_WHISPER_LANGUAGE ?? "en-IN";
const authToken = await ensureLocalAuthToken();
const controlRate = new SlidingWindowRateLimiter(20, 60_000);

const transcriptionServer =
  transport === "sdk"
    ? (await import("./sdk-server.ts")).createSdkDaemon({
        authToken,
        hostname,
        speculativeIntelligence: true,
      })
    : createDaemon({
        authToken,
        hostname,
        port: optionalPort(Bun.env.GEMINI_WHISPER_PORT),
        label: "system-native",
        speculativeIntelligence: true,
      });

let microphone: ReturnType<typeof Bun.spawn> | undefined;
let stopping = false;
let stopRequestedAtNs = 0;
let targetApplication: Promise<string | undefined> | undefined;
let audioHelperSocket: Bun.Socket<undefined> | undefined;
let audioRelaySocket: Bun.Socket<undefined> | undefined;
let audioHelperLaunching = false;
let shuttingDown = false;
let diagnosticAudio: Uint8Array[] | undefined;

const audioHelperReceiver = Bun.listen({
  hostname,
  port: 0,
  socket: {
    data(_socket, data) {
      if (diagnosticAudio) diagnosticAudio.push(data.slice());
      audioRelaySocket?.write(data);
    },
    open(socket) {
      audioHelperSocket?.end();
      audioHelperSocket = socket;
      audioHelperLaunching = false;
      console.log(`Persistent macOS audio helper connected on ${audioHelperReceiver.port}.`);
      if (audioRelaySocket && microphone && !stopping) socket.write("1");
    },
    close(socket) {
      if (socket === audioHelperSocket) audioHelperSocket = undefined;
      if (!shuttingDown) setTimeout(() => void launchPersistentAudioHelper(), 500);
    },
    error(_socket, error) {
      console.error(`Persistent macOS audio helper failed: ${error.message}`);
    },
  },
});

const audioRelayServer = Bun.listen({
  hostname,
  port: 0,
  socket: {
    data() {},
    open(socket) {
      audioRelaySocket?.end();
      audioRelaySocket = socket;
      if (audioHelperSocket && microphone && !stopping) audioHelperSocket.write("1");
    },
    close(socket) {
      if (socket === audioRelaySocket) audioRelaySocket = undefined;
      audioHelperSocket?.write("0");
    },
    error(_socket, error) {
      console.error(`Local audio relay failed: ${error.message}`);
    },
  },
});

const hotkeyServer = Bun.serve({
  hostname,
  port: hotkeyPort,
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return Response.json({
        ok: true,
        transport,
        microphone: microphoneState(),
        transcriptionPort: transcriptionServer.port,
      });
    }
    if (request.headers.has("origin")) {
      return new Response("Browser origins are not allowed", { status: 403 });
    }
    if (!requestHasBearerToken(request, authToken)) {
      return new Response("Unauthorized", { status: 401 });
    }
    if (!controlRate.accept()) {
      return new Response("Too many control requests", {
        status: 429,
        headers: { "Retry-After": "3" },
      });
    }
    if (request.method === "POST" && url.pathname === "/toggle") {
      return Response.json(toggleMicrophone());
    }
    if (url.pathname === "/permissions") {
      return Response.json({ pasteAutomation: await hasPasteAutomationPermission() });
    }
    if (request.method === "POST" && url.pathname === "/audio-check") {
      if (microphone) return Response.json({ error: "Dictation is active." }, { status: 409 });
      return Response.json(await checkBackgroundAudio());
    }
    return new Response("Not found", { status: 404 });
  },
});

console.log(`System service ready: ${transport} transcription + right Option on ${hotkeyServer.port}.`);
void launchPersistentAudioHelper();

function toggleMicrophone(): { microphone: string } {
  if (!microphone) {
    startMicrophone();
    return { microphone: "starting" };
  }
  if (stopping) return { microphone: "finalizing" };

  stopping = true;
  stopRequestedAtNs = Bun.nanoseconds();
  console.log("Right Option: stopping and polishing dictation.");
  playSound("Pop");
  audioHelperSocket?.write("0");
  microphone.stdin.write("\n");
  microphone.stdin.end();
  return { microphone: "finalizing" };
}

function startMicrophone(): void {
  const args = [process.execPath, "run", "src/cli.ts", "mic", "--system"];
  const device = Bun.env.GEMINI_WHISPER_AUDIO_DEVICE;
  const language = systemLanguage;
  if (device) args.push("--device", device);
  if (language) args.push("--language", language);
  args.push("--automatic-vad");
  if (process.platform === "darwin") args.push("--audio-relay-port", String(audioRelayServer.port));

  console.log("Right Option: starting dictation.");
  targetApplication = frontmostApplication();
  microphone = Bun.spawn(args, {
    cwd: projectRoot,
    env: Bun.env,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  playSound("Tink");
  const child = microphone;
  const output = watchMachineOutput(child.stdout);
  const stderr = new Response(child.stderr).text();
  let receivedResult = false;

  void output.result.then(async (result) => {
    if (!result?.text) return;
    receivedResult = true;
    // The transcript is complete. Do not make insertion wait for the one-shot
    // audio app and Launch Services process to finish cleaning themselves up.
    child.kill("SIGTERM");
    try {
      const pasted = await pasteIntoFocusedApplication(result.text, await targetApplication);
      playSound(pasted ? "Glass" : "Pop");
      const stopToPasteMs =
        stopRequestedAtNs > 0 ? Math.round((Bun.nanoseconds() - stopRequestedAtNs) / 1_000_000) : 0;
      console.log(
        `${pasted ? "Inserted" : "Copied"} ${result.text.length} characters in ${stopToPasteMs} ms after stop ` +
          `(Flash-Lite ${result.polishLatencyMs} ms, ` +
          `${result.speculative ? "overlapped" : "after final"}).`,
      );
      stopRequestedAtNs = 0;
    } catch (error) {
      playSound("Basso");
      console.error(error instanceof Error ? error.message : "Could not insert dictated text.");
    }
  });

  void child.exited.then(async (exitCode) => {
    const [, errors] = await Promise.all([output.done, stderr]);
    microphone = undefined;
    stopping = false;
    targetApplication = undefined;

    if (errors.trim()) console.error(errors.trim());
    if (exitCode !== 0 && !receivedResult) {
      playSound("Basso");
      notifyDictationFailure(errors);
      console.error(`Microphone process exited with code ${exitCode}.`);
      return;
    }
    if (!receivedResult) {
      playSound("Basso");
      showNotification("No transcript was returned. Please try again.");
      console.error("Dictation completed without text.");
    }
  });
}

function notifyDictationFailure(detail: string): void {
  const message = detail.includes("exceeded your current quota")
    ? "Gemini Live quota is temporarily unavailable. Try again after the quota resets."
    : detail.includes("final_transcript_timeout")
      ? "Gemini did not finalize this transcript. Please try again."
      : "Dictation failed. Check the Gemini Whisper log for details.";
  showNotification(message);
}

function showNotification(message: string): void {
  const notification = Bun.spawn(
    [
      "/usr/bin/osascript",
      "-e",
      'on run argv\ndisplay notification (item 1 of argv) with title "Gemini Whisper"\nend run',
      "--",
      message,
    ],
    { stdin: "ignore", stdout: "ignore", stderr: "ignore" },
  );
  void notification.exited;
}

async function hasPasteAutomationPermission(): Promise<boolean> {
  const check = Bun.spawn(
    ["/usr/bin/osascript", "-e", 'tell application "System Events" to get UI elements enabled'],
    { stdout: "pipe", stderr: "ignore" },
  );
  const output = new Response(check.stdout).text();
  return (await check.exited) === 0 && (await output).trim() === "true";
}

async function checkBackgroundAudio(): Promise<{
  source: string;
  bytes: number;
  rms: number;
  peak: number;
  exitCode: number;
  error: string;
}> {
  const device = Bun.env.GEMINI_WHISPER_AUDIO_DEVICE ?? ":0";
  if (process.platform === "darwin") {
    if (!audioHelperSocket) {
      return {
        source: "Gemini Whisper Audio persistent helper",
        bytes: 0,
        rms: 0,
        peak: 0,
        exitCode: 1,
        error: "Persistent audio helper is not connected.",
      };
    }
    diagnosticAudio = [];
    audioHelperSocket.write("1");
    await Bun.sleep(1_000);
    audioHelperSocket.write("0");
    const chunks = diagnosticAudio;
    diagnosticAudio = undefined;
    const totalBytes = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
    const audio = new Uint8Array(totalBytes);
    let offset = 0;
    for (const chunk of chunks) {
      audio.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return {
      source: "Gemini Whisper Audio persistent helper",
      bytes: audio.byteLength,
      ...analyzePcm(audio),
      exitCode: 0,
      error: "",
    };
  }

  const inputArgs =
    ["-f", "pulse", "-i", device === ":0" ? "default" : device];
  const command = [
    "ffmpeg",
    "-hide_banner",
    "-loglevel",
    "error",
    ...inputArgs,
    "-t",
    "1",
    "-vn",
    "-ac",
    "1",
    "-ar",
    "16000",
    "-acodec",
    "pcm_s16le",
    "-f",
    "s16le",
    "pipe:1",
  ];
  const capture = Bun.spawn(
    command,
    { stdin: "ignore", stdout: "pipe", stderr: "pipe" },
  );
  const output = new Response(capture.stdout).bytes();
  const error = new Response(capture.stderr).text();
  const exitCode = await capture.exited;
  const audio = await output;
  const signal = analyzePcm(audio);
  return {
    source: device,
    bytes: audio.byteLength,
    ...signal,
    exitCode,
    error: (await error).trim(),
  };
}

async function launchPersistentAudioHelper(): Promise<void> {
  if (process.platform !== "darwin" || shuttingDown || audioHelperSocket || audioHelperLaunching) {
    return;
  }
  audioHelperLaunching = true;
  const launch = Bun.spawn(
    [
      "/usr/bin/open",
      "-n",
      "-g",
      audioHelperApp,
      "--args",
      "--port",
      String(audioHelperReceiver.port),
      "--persistent",
    ],
    { stdin: "ignore", stdout: "ignore", stderr: "pipe" },
  );
  const error = new Response(launch.stderr).text();
  const exitCode = await launch.exited;
  const detail = (await error).trim();
  if (exitCode !== 0 || detail) {
    audioHelperLaunching = false;
    console.error(detail || `Could not launch persistent audio helper (exit ${exitCode}).`);
  }
}

function analyzePcm(audio: Uint8Array): { rms: number; peak: number } {
  const view = new DataView(audio.buffer, audio.byteOffset, audio.byteLength);
  const usableBytes = audio.byteLength - (audio.byteLength % 2);
  let samples = 0;
  let sumSquares = 0;
  let peak = 0;
  for (let offset = 0; offset < usableBytes; offset += 2) {
    const sample = view.getInt16(offset, true);
    sumSquares += sample * sample;
    peak = Math.max(peak, Math.abs(sample));
    samples++;
  }
  return { rms: samples > 0 ? Math.round(Math.sqrt(sumSquares / samples)) : 0, peak };
}

function playSound(name: "Tink" | "Pop" | "Glass" | "Basso"): void {
  const sound = Bun.spawn(["/usr/bin/afplay", `/System/Library/Sounds/${name}.aiff`], {
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
  });
  void sound.exited;
}

type MachineResult = {
  text: string;
  polished: boolean;
  polishLatencyMs: number;
  speculative: boolean;
};

function watchMachineOutput(stream: ReadableStream<Uint8Array>): {
  result: Promise<MachineResult | undefined>;
  done: Promise<void>;
} {
  let resolveResult!: (result: MachineResult | undefined) => void;
  let resolved = false;
  const result = new Promise<MachineResult | undefined>((resolve) => (resolveResult = resolve));
  const done = (async () => {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let pending = "";
    try {
      while (true) {
        const { done, value } = await reader.read();
        pending += decoder.decode(value, { stream: !done });
        const lines = pending.split("\n");
        pending = lines.pop() ?? "";
        for (const line of lines) {
          const parsed = parseMachineResult(line);
          if (parsed && !resolved) {
            resolved = true;
            resolveResult(parsed);
          }
        }
        if (done) break;
      }
      const parsed = parseMachineResult(pending);
      if (parsed && !resolved) {
        resolved = true;
        resolveResult(parsed);
      }
    } finally {
      reader.releaseLock();
      if (!resolved) resolveResult(undefined);
    }
  })();
  return { result, done };
}

function parseMachineResult(
  output: string,
): MachineResult | undefined {
  const line = output.trim().split("\n").at(-1);
  if (!line) return undefined;
  try {
    const value = JSON.parse(line) as {
      text?: unknown;
      polished?: unknown;
      polishLatencyMs?: unknown;
      speculative?: unknown;
    };
    if (typeof value.text !== "string") return undefined;
    return {
      text: value.text,
      polished: value.polished === true,
      polishLatencyMs:
        typeof value.polishLatencyMs === "number" ? Math.round(value.polishLatencyMs) : 0,
      speculative: value.speculative === true,
    };
  } catch {
    return undefined;
  }
}

async function pasteIntoFocusedApplication(
  text: string,
  expectedApplication: string | undefined,
): Promise<boolean> {
  const currentApplication = await frontmostApplication();
  if (expectedApplication && currentApplication && currentApplication !== expectedApplication) {
    await copyText(text);
    showNotification(
      `Focus moved from ${expectedApplication} to ${currentApplication}. The transcript was copied instead of pasted.`,
    );
    return false;
  }

  const paste = Bun.spawn(
    [
      "/usr/bin/osascript",
      "-e",
      `on run argv
set dictatedText to item 1 of argv
set oldClipboard to missing value
try
  set oldClipboard to the clipboard as record
  set the clipboard to dictatedText
  tell application "System Events" to keystroke "v" using command down
  delay 0.15
  if oldClipboard is not missing value then set the clipboard to oldClipboard
on error errorMessage number errorNumber
  if oldClipboard is not missing value then set the clipboard to oldClipboard
  error errorMessage number errorNumber
end try
end run`,
      "--",
      text,
    ],
    { stdout: "ignore", stderr: "pipe" },
  );
  const pasteError = new Response(paste.stderr).text();
  const pasteExit = await paste.exited;
  if (pasteExit !== 0) {
    throw new Error((await pasteError).trim() || "macOS paste automation failed.");
  }
  return true;
}

async function copyText(text: string): Promise<void> {
  const copy = Bun.spawn(["/usr/bin/osascript", "-e", "on run argv", "-e", "set the clipboard to item 1 of argv", "-e", "end run", "--", text], {
    stdin: "ignore",
    stdout: "ignore",
    stderr: "pipe",
  });
  const detail = new Response(copy.stderr).text();
  if ((await copy.exited) !== 0) {
    throw new Error((await detail).trim() || "Could not copy the transcript.");
  }
}

async function frontmostApplication(): Promise<string | undefined> {
  const process = Bun.spawn(
    [
      "/usr/bin/osascript",
      "-e",
      'tell application "System Events" to get name of first application process whose frontmost is true',
    ],
    { stdin: "ignore", stdout: "pipe", stderr: "ignore" },
  );
  const output = new Response(process.stdout).text();
  if ((await process.exited) !== 0) return undefined;
  return (await output).trim() || undefined;
}

function microphoneState(): string {
  if (!microphone) return "idle";
  return stopping ? "finalizing" : "listening";
}

function optionalPort(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const port = Number(value);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error(`Invalid port: ${value}`);
  return port;
}

function shutdown(): void {
  shuttingDown = true;
  microphone?.kill("SIGTERM");
  audioHelperSocket?.write("q");
  audioHelperSocket?.end();
  audioRelaySocket?.end();
  audioHelperReceiver.stop(true);
  audioRelayServer.stop(true);
  hotkeyServer.stop(true);
  transcriptionServer.stop(true);
  process.exit(0);
}

process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
