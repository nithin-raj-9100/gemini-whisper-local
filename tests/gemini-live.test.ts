import { describe, expect, test } from "bun:test";
import {
  GeminiLiveTranscriber,
  buildGeminiSetup,
  parseGeminiMessage,
} from "../src/gemini-live.ts";
import { DEFAULT_TRANSCRIPTION_CONFIG } from "../src/types.ts";

describe("Gemini wire protocol", () => {
  test("builds a SMART transcription setup", () => {
    expect(
      buildGeminiSetup({
        ...DEFAULT_TRANSCRIPTION_CONFIG,
        languageCodes: ["en-IN"],
        customVocabulary: ["Bun"],
      }),
    ).toEqual({
      setup: {
        model: "models/gemini-3.5-transcribe-live",
        generationConfig: { responseModalities: ["TEXT"] },
        inputAudioTranscription: {
          languageCodes: ["en-IN"],
          customVocabulary: ["Bun"],
          mode: "SMART",
        },
        realtimeInputConfig: {
          automaticActivityDetection: {
            disabled: false,
            startOfSpeechSensitivity: "START_SENSITIVITY_HIGH",
            endOfSpeechSensitivity: "END_SENSITIVITY_LOW",
            prefixPaddingMs: 500,
            silenceDurationMs: 1500,
          },
        },
      },
    });
  });

  test("adds manual VAD configuration", () => {
    const message = buildGeminiSetup({ ...DEFAULT_TRANSCRIPTION_CONFIG, vad: "manual" });
    expect(message).toMatchObject({
      setup: { realtimeInputConfig: { automaticActivityDetection: { disabled: true } } },
    });
  });

  test("extracts setup, interim, final, and completion events", () => {
    expect(parseGeminiMessage({ setupComplete: {} })).toEqual([{ type: "ready" }]);
    expect(
      parseGeminiMessage({
        serverContent: {
          interimInputTranscription: { text: "hel" },
          inputTranscription: { text: "Hello." },
          turnComplete: true,
        },
      }),
    ).toEqual([
      { type: "interim", text: "hel" },
      { type: "final", text: "Hello." },
      { type: "complete" },
    ]);
  });

  test("runs the raw WebSocket setup, audio, and finish lifecycle", async () => {
    const socket = new FakeWebSocket();
    const eventTypes: string[] = [];
    const transcriber = new GeminiLiveTranscriber({
      apiKey: "test-only",
      config: DEFAULT_TRANSCRIPTION_CONFIG,
      emit: (event) => eventTypes.push(event.type),
      webSocketFactory: () => socket as unknown as WebSocket,
    });

    const connected = transcriber.connect();
    socket.open();
    expect(JSON.parse(socket.sent[0]!)).toEqual(buildGeminiSetup(DEFAULT_TRANSCRIPTION_CONFIG));
    socket.message({ setupComplete: {} });
    await connected;
    await Bun.sleep(0);

    expect(eventTypes).toEqual(["ready", "speech-start"]);
    transcriber.sendAudio(new Uint8Array([1, 0]));
    expect(JSON.parse(socket.sent[1]!)).toEqual({
      realtimeInput: {
        audio: { data: "AQA=", mimeType: "audio/pcm;rate=16000" },
      },
    });
    socket.message({ serverContent: { turnComplete: true } });
    await Bun.sleep(0);
    expect(eventTypes).toEqual(["ready", "speech-start"]);
    expect(() => transcriber.sendAudio(new Uint8Array([2, 0]))).not.toThrow();
    transcriber.finish();
    expect(JSON.parse(socket.sent[3]!)).toEqual({ realtimeInput: { audioStreamEnd: true } });

    socket.message({
      serverContent: { inputTranscription: { text: "Hello." }, turnComplete: true },
    });
    await Bun.sleep(0);
    expect(eventTypes).toEqual([
      "ready",
      "speech-start",
      "speech-end",
      "final",
      "complete",
    ]);
  });

  test("finishes immediately when automatic VAD already completed the last audio", async () => {
    const socket = new FakeWebSocket();
    const eventTypes: string[] = [];
    const transcriber = new GeminiLiveTranscriber({
      apiKey: "test-only",
      config: DEFAULT_TRANSCRIPTION_CONFIG,
      emit: (event) => eventTypes.push(event.type),
      webSocketFactory: () => socket as unknown as WebSocket,
    });

    const connected = transcriber.connect();
    socket.open();
    socket.message({ setupComplete: {} });
    await connected;
    await Bun.sleep(0);
    transcriber.sendAudio(new Uint8Array([1, 0]));
    // Gemini only completes a turn after observing silenceDurationMs of quiet,
    // so let that pause elapse before the complete provably finalizes the audio.
    await Bun.sleep(900);
    socket.message({
      serverContent: { inputTranscription: { text: "Already final." }, turnComplete: true },
    });
    await Bun.sleep(0);

    const sentBeforeFinish = socket.sent.length;
    transcriber.finish();

    expect(socket.sent).toHaveLength(sentBeforeFinish);
    expect(eventTypes).toEqual([
      "ready",
      "speech-start",
      "final",
      "speech-end",
      "complete",
    ]);
  });

  test("promotes an interim hypothesis when turn completion omits a final transcript", async () => {
    const socket = new FakeWebSocket();
    const events: Array<{ type: string; text?: string }> = [];
    const transcriber = new GeminiLiveTranscriber({
      apiKey: "test-only",
      config: DEFAULT_TRANSCRIPTION_CONFIG,
      emit: (event) => events.push(event),
      webSocketFactory: () => socket as unknown as WebSocket,
    });

    const connected = transcriber.connect();
    socket.open();
    socket.message({ setupComplete: {} });
    await connected;
    await Bun.sleep(0);
    transcriber.sendAudio(new Uint8Array([1, 0]));
    await Bun.sleep(900);
    socket.message({
      serverContent: { interimInputTranscription: { text: "Buffered words" }, turnComplete: true },
    });
    await Bun.sleep(0);
    transcriber.finish();

    expect(events).toContainEqual({ type: "final", text: "Buffered words" });
    expect(events.at(-1)?.type).toBe("complete");
  });

  test("does not skip finalization when a late turn complete races with recent audio", async () => {
    const socket = new FakeWebSocket();
    const events: Array<{ type: string; text?: string }> = [];
    const transcriber = new GeminiLiveTranscriber({
      apiKey: "test-only",
      config: DEFAULT_TRANSCRIPTION_CONFIG,
      emit: (event) => events.push(event),
      webSocketFactory: () => socket as unknown as WebSocket,
    });

    const connected = transcriber.connect();
    socket.open();
    socket.message({ setupComplete: {} });
    await connected;
    await Bun.sleep(0);
    // Resumed speech after a mid-dictation pause, with Gemini's turnComplete
    // for the paused turn still arriving afterwards.
    transcriber.sendAudio(new Uint8Array([1, 0]));
    socket.message({ serverContent: { turnComplete: true } });
    await Bun.sleep(0);
    transcriber.finish();

    expect(JSON.parse(socket.sent[socket.sent.length - 1]!)).toEqual({
      realtimeInput: { audioStreamEnd: true },
    });
    expect(events.some((event) => event.type === "complete")).toBe(false);

    socket.message({
      serverContent: { inputTranscription: { text: "Resumed speech." }, turnComplete: true },
    });
    await Bun.sleep(0);
    expect(events).toContainEqual({ type: "final", text: "Resumed speech." });
    expect(events.at(-1)?.type).toBe("complete");
  });

  test("reconnects an unexpected upstream close and flushes buffered audio", async () => {
    const sockets: FakeWebSocket[] = [];
    const eventTypes: string[] = [];
    const transcriber = new GeminiLiveTranscriber({
      apiKey: "test-only",
      config: DEFAULT_TRANSCRIPTION_CONFIG,
      emit: (event) => eventTypes.push(event.type),
      webSocketFactory: () => {
        const socket = new FakeWebSocket();
        sockets.push(socket);
        return socket as unknown as WebSocket;
      },
    });

    const connected = transcriber.connect();
    sockets[0]!.open();
    sockets[0]!.message({ setupComplete: {} });
    await connected;
    await Bun.sleep(0);
    sockets[0]!.remoteClose(1000, "Connection ended");
    transcriber.sendAudio(new Uint8Array([3, 0]));

    await Bun.sleep(250);
    expect(sockets).toHaveLength(2);
    sockets[1]!.open();
    sockets[1]!.message({ setupComplete: {} });
    await Bun.sleep(0);

    expect(eventTypes).toEqual([
      "ready",
      "speech-start",
      "connecting",
      "ready",
      "speech-start",
    ]);
    expect(JSON.parse(sockets[1]!.sent[1]!)).toMatchObject({
      realtimeInput: { audio: { data: "AwA=" } },
    });
    transcriber.close();
  });
});

class FakeWebSocket extends EventTarget {
  readyState = WebSocket.CONNECTING;
  sent: string[] = [];

  send(data: string): void {
    this.sent.push(data);
  }

  close(): void {
    if (this.readyState === WebSocket.CLOSED) return;
    this.readyState = WebSocket.CLOSED;
    this.dispatchEvent(new CloseEvent("close", { code: 1000, reason: "test complete" }));
  }

  remoteClose(code: number, reason: string): void {
    this.readyState = WebSocket.CLOSED;
    this.dispatchEvent(new CloseEvent("close", { code, reason }));
  }

  open(): void {
    this.readyState = WebSocket.OPEN;
    this.dispatchEvent(new Event("open"));
  }

  message(value: unknown): void {
    this.dispatchEvent(new MessageEvent("message", { data: JSON.stringify(value) }));
  }
}
