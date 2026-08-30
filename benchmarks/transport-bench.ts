const variant = process.argv[2];
const messageCount = Number(process.argv[3] ?? 10_000);
const chunk = new Uint8Array(3_200);
const encodedAudio = chunk.toBase64();

if (variant !== "native" && variant !== "sdk") {
  throw new Error("Usage: bun benchmarks/transport-bench.ts <native|sdk> [message-count]");
}
if (!Number.isSafeInteger(messageCount) || messageCount < 1) {
  throw new Error("message-count must be a positive integer");
}

let received = 0;
let resolveReceived!: () => void;
const allReceived = new Promise<void>((resolve) => (resolveReceived = resolve));

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch(request, server) {
    return server.upgrade(request) ? undefined : new Response("upgrade required", { status: 426 });
  },
  websocket: {
    message(socket, rawMessage) {
      const message = typeof rawMessage === "string" ? rawMessage : new TextDecoder().decode(rawMessage);
      if (message.includes('"setup"')) {
        socket.send(JSON.stringify({ setupComplete: {} }));
        return;
      }
      received++;
      if (received === messageCount) resolveReceived();
    },
  },
});

const cpuStart = process.cpuUsage();
const memoryStart = process.memoryUsage();
const rssStart = memoryStart.rss;
let rssConnected = rssStart;
const startedAt = Bun.nanoseconds();

if (variant === "native") {
  await runNative();
} else {
  await runSdk();
}

await allReceived;
const elapsedSeconds = (Bun.nanoseconds() - startedAt) / 1e9;
const cpu = process.cpuUsage(cpuStart);
const memoryEnd = process.memoryUsage();
const rssEnd = memoryEnd.rss;

server.stop(true);

console.log(
  JSON.stringify({
    variant,
    messages: messageCount,
    messagesPerSecond: messageCount / elapsedSeconds,
    elapsedSeconds,
    userCpuMs: cpu.user / 1_000,
    systemCpuMs: cpu.system / 1_000,
    totalCpuMs: (cpu.user + cpu.system) / 1_000,
    rssStartMiB: rssStart / 1024 / 1024,
    rssConnectedMiB: rssConnected / 1024 / 1024,
    rssEndMiB: rssEnd / 1024 / 1024,
    rssGrowthMiB: (rssEnd - rssStart) / 1024 / 1024,
  }),
);

async function runNative(): Promise<void> {
  const socket = new WebSocket(`ws://127.0.0.1:${server.port}/benchmark`);
  await new Promise<void>((resolve, reject) => {
    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ setup: { model: "models/benchmark" } }));
    });
    socket.addEventListener("message", () => resolve(), { once: true });
    socket.addEventListener("error", () => reject(new Error("native WebSocket failed")), {
      once: true,
    });
  });
  const connectedMemory = process.memoryUsage();
  rssConnected = connectedMemory.rss;

  for (let index = 0; index < messageCount; index++) {
    socket.send(
      JSON.stringify({
        realtimeInput: { audio: { data: encodedAudio, mimeType: "audio/pcm;rate=16000" } },
      }),
    );
  }
  await allReceived;
  socket.close();
}

async function runSdk(): Promise<void> {
  const { GoogleGenAI, Modality } = await import("@google/genai/web");
  const client = new GoogleGenAI({
    apiKey: "benchmark-only",
    httpOptions: { baseUrl: `http://127.0.0.1:${server.port}` },
  });
  const session = await client.live.connect({
    model: "gemini-3.5-transcribe-live",
    config: { responseModalities: [Modality.TEXT] },
    callbacks: { onmessage() {} },
  });
  const connectedMemory = process.memoryUsage();
  rssConnected = connectedMemory.rss;

  for (let index = 0; index < messageCount; index++) {
    session.sendRealtimeInput({
      audio: { data: encodedAudio, mimeType: "audio/pcm;rate=16000" },
    });
  }
  await allReceived;
  session.close();
}
