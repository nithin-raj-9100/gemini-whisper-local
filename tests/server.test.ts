import { describe, expect, test } from "bun:test";
import type { LiveTranscriber } from "../src/gemini-live.ts";
import { createDaemon } from "../src/server.ts";
import { websocketAuthProtocol } from "../src/local-auth.ts";
import type { ServerEvent } from "../src/types.ts";

const TEST_AUTH_TOKEN = "a".repeat(64);

class FakeTranscriber implements LiveTranscriber {
  audioBytes = 0;
  finishCalled = false;
  completeEmitted = false;

  constructor(private readonly emit: (event: ServerEvent) => void) {}

  async connect(): Promise<void> {
    this.emit({ type: "ready" });
    this.emit({ type: "speech-start" });
  }

  sendAudio(chunk: Uint8Array): void {
    this.audioBytes += chunk.byteLength;
    this.emit({ type: "interim", text: "testing" });
  }

  finish(): void {
    this.finishCalled = true;
    this.emit({ type: "speech-end" });
    this.emit({ type: "final", text: "Testing." });
    this.completeEmitted = true;
    this.emit({ type: "complete" });
  }

  close(): void {}
}

describe("local daemon", () => {
  test("bridges binary audio to a live transcriber and emits transcript events", async () => {
    let fake: FakeTranscriber | undefined;
    const server = createDaemon({
      authToken: TEST_AUTH_TOKEN,
      apiKey: "test-only",
      port: 0,
      quiet: true,
      intelligence: false,
      sessionFactory(_config, emit) {
        fake = new FakeTranscriber(emit);
        return fake;
      },
    });

    try {
      const events: ServerEvent[] = [];
      const socket = new WebSocket(
        `ws://127.0.0.1:${server.port}/v1/transcribe`,
        websocketAuthProtocol(TEST_AUTH_TOKEN),
      );
      socket.addEventListener("message", (message) => {
        const event = JSON.parse(String(message.data)) as ServerEvent;
        events.push(event);
        if (event.type === "hello") socket.send(JSON.stringify({ type: "start" }));
        if (event.type === "ready") socket.send(new Uint8Array(3200));
        if (event.type === "interim") socket.send(JSON.stringify({ type: "stop" }));
        if (event.type === "complete") socket.close();
      });
      await Promise.race([
        new Promise<void>((resolve) => socket.addEventListener("close", () => resolve())),
        Bun.sleep(2_000).then(() => {
          throw new Error("Local WebSocket integration test timed out.");
        }),
      ]);

      expect(fake?.audioBytes).toBe(3200);
      expect(events.map((event) => event.type)).toEqual([
        "hello",
        "connecting",
        "ready",
        "speech-start",
        "interim",
        "speech-end",
        "final",
        "complete",
      ]);
    } finally {
      server.stop(true);
    }
  });

  test("polishes the accumulated final transcript before completing", async () => {
    const server = createDaemon({
      authToken: TEST_AUTH_TOKEN,
      apiKey: "test-only",
      port: 0,
      quiet: true,
      sessionFactory(_config, emit) {
        return new FakeTranscriber(emit);
      },
      intelligence: {
        async polish(transcript) {
          expect(transcript).toBe("Testing.");
          return {
            text: "1. Milk\n2. Vegetables",
            model: "test-flash-lite",
            latencyMs: 3,
          };
        },
      },
    });

    try {
      const events: ServerEvent[] = [];
      const socket = new WebSocket(
        `ws://127.0.0.1:${server.port}/v1/transcribe`,
        websocketAuthProtocol(TEST_AUTH_TOKEN),
      );
      socket.addEventListener("message", (message) => {
        const event = JSON.parse(String(message.data)) as ServerEvent;
        events.push(event);
        if (event.type === "hello") socket.send(JSON.stringify({ type: "start" }));
        if (event.type === "ready") socket.send(new Uint8Array(3200));
        if (event.type === "interim") socket.send(JSON.stringify({ type: "stop" }));
        if (event.type === "complete") socket.close();
      });
      await Promise.race([
        new Promise<void>((resolve) => socket.addEventListener("close", () => resolve())),
        Bun.sleep(2_000).then(() => {
          throw new Error("Local WebSocket intelligence test timed out.");
        }),
      ]);

      expect(events.at(-2)).toEqual({
        type: "polished",
        text: "1. Milk\n2. Vegetables",
        model: "test-flash-lite",
        latencyMs: 3,
      });
      expect(events.at(-1)?.type).toBe("complete");
    } finally {
      server.stop(true);
    }
  });

  test("skips intelligence when polishing is disabled", async () => {
    let polishCalls = 0;
    const server = createDaemon({
      authToken: TEST_AUTH_TOKEN,
      apiKey: "test-only",
      port: 0,
      quiet: true,
      sessionFactory(_config, emit) {
        return new FakeTranscriber(emit);
      },
      intelligence: {
        async polish() {
          polishCalls++;
          return { text: "unexpected", model: "test-flash-lite", latencyMs: 1 };
        },
      },
    });

    try {
      const events: ServerEvent[] = [];
      const socket = new WebSocket(
        `ws://127.0.0.1:${server.port}/v1/transcribe`,
        websocketAuthProtocol(TEST_AUTH_TOKEN),
      );
      socket.addEventListener("message", (message) => {
        const event = JSON.parse(String(message.data)) as ServerEvent;
        events.push(event);
        if (event.type === "hello") {
          socket.send(JSON.stringify({ type: "start", config: { polish: false } }));
        }
        if (event.type === "ready") socket.send(new Uint8Array(3200));
        if (event.type === "interim") socket.send(JSON.stringify({ type: "stop" }));
        if (event.type === "complete") socket.close();
      });
      await Promise.race([
        new Promise<void>((resolve) => socket.addEventListener("close", () => resolve())),
        Bun.sleep(2_000).then(() => {
          throw new Error("No-polish integration test timed out.");
        }),
      ]);
      expect(polishCalls).toBe(0);
      expect(events.some((event) => event.type === "polished")).toBe(false);
    } finally {
      server.stop(true);
    }
  });

  test("starts speculative polishing before transcription finalization", async () => {
    let fake: FakeTranscriber | undefined;
    let polishCalls = 0;
    const server = createDaemon({
      authToken: TEST_AUTH_TOKEN,
      apiKey: "test-only",
      port: 0,
      quiet: true,
      speculativeIntelligence: true,
      sessionFactory(_config, emit) {
        fake = new FakeTranscriber(emit);
        return fake;
      },
      intelligence: {
        async polish(transcript) {
          polishCalls++;
          expect(transcript.toLowerCase().replace(/\.$/, "")).toBe("testing");
          expect(fake?.completeEmitted).toBe(false);
          await Bun.sleep(20);
          return { text: "Testing.", model: "test-flash-lite", latencyMs: 20 };
        },
      },
    });

    try {
      const events: ServerEvent[] = [];
      const socket = new WebSocket(
        `ws://127.0.0.1:${server.port}/v1/transcribe`,
        websocketAuthProtocol(TEST_AUTH_TOKEN),
      );
      socket.addEventListener("message", (message) => {
        const event = JSON.parse(String(message.data)) as ServerEvent;
        events.push(event);
        if (event.type === "hello") socket.send(JSON.stringify({ type: "start" }));
        if (event.type === "ready") socket.send(new Uint8Array(3200));
        if (event.type === "interim") socket.send(JSON.stringify({ type: "stop" }));
        if (event.type === "complete") socket.close();
      });
      await Promise.race([
        new Promise<void>((resolve) => socket.addEventListener("close", () => resolve())),
        Bun.sleep(2_000).then(() => {
          throw new Error("Speculative intelligence test timed out.");
        }),
      ]);
      expect(polishCalls).toBe(1);
      expect(events.some((event) => event.type === "polished" && event.speculative)).toBe(true);
    } finally {
      server.stop(true);
    }
  });
});
