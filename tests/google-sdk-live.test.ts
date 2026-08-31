import { describe, expect, test } from "bun:test";
import {
  AudioTranscriptionConfigMode,
  EndSensitivity,
  Modality,
  StartSensitivity,
  type LiveConnectParameters,
  type Session,
} from "@google/genai/web";
import {
  GoogleSdkLiveTranscriber,
  buildSdkLiveConfig,
  sdkMessageToEvents,
} from "../src/google-sdk-live.ts";
import { DEFAULT_TRANSCRIPTION_CONFIG } from "../src/types.ts";

describe("Google SDK variant", () => {
  test("maps the shared config to SDK-native enums", () => {
    expect(buildSdkLiveConfig(DEFAULT_TRANSCRIPTION_CONFIG)).toEqual({
      responseModalities: [Modality.TEXT],
      inputAudioTranscription: {
        languageCodes: [],
        customVocabulary: [],
        mode: AudioTranscriptionConfigMode.SMART,
      },
      realtimeInputConfig: {
        automaticActivityDetection: {
          disabled: false,
          startOfSpeechSensitivity: StartSensitivity.START_SENSITIVITY_HIGH,
          endOfSpeechSensitivity: EndSensitivity.END_SENSITIVITY_LOW,
          prefixPaddingMs: 500,
          silenceDurationMs: 1500,
        },
      },
    });
  });

  test("extracts interim and final SDK events", () => {
    expect(
      sdkMessageToEvents({
        serverContent: {
          interimInputTranscription: { text: "Hel" },
          inputTranscription: { text: "Hello." },
          turnComplete: true,
        },
      }),
    ).toEqual([
      { type: "interim", text: "Hel" },
      { type: "final", text: "Hello." },
      { type: "complete" },
    ]);
  });

  test("runs audio and completion through an injected SDK session", async () => {
    const sent: unknown[] = [];
    let parameters: LiveConnectParameters | undefined;
    const fakeSession = {
      sendRealtimeInput(value: unknown) {
        sent.push(value);
      },
      close() {},
    } as unknown as Session;
    const eventTypes: string[] = [];
    const transcriber = new GoogleSdkLiveTranscriber({
      apiKey: "test-only",
      config: DEFAULT_TRANSCRIPTION_CONFIG,
      emit: (event) => eventTypes.push(event.type),
      async connectSession(value) {
        parameters = value;
        return fakeSession;
      },
    });

    await transcriber.connect();
    transcriber.sendAudio(new Uint8Array([1, 0]));
    transcriber.finish();
    parameters!.callbacks.onmessage({
      serverContent: { inputTranscription: { text: "Hello." } },
    });

    expect(sent).toEqual([
      { audio: { data: "AQA=", mimeType: "audio/pcm;rate=16000" } },
      { audioStreamEnd: true },
    ]);
    expect(eventTypes).toEqual([
      "ready",
      "speech-start",
      "speech-end",
      "final",
      "complete",
    ]);
  });

  test("finishes immediately when SDK automatic VAD already completed the last audio", async () => {
    const sent: unknown[] = [];
    let parameters: LiveConnectParameters | undefined;
    const fakeSession = {
      sendRealtimeInput(value: unknown) {
        sent.push(value);
      },
      close() {},
    } as unknown as Session;
    const eventTypes: string[] = [];
    const transcriber = new GoogleSdkLiveTranscriber({
      apiKey: "test-only",
      config: DEFAULT_TRANSCRIPTION_CONFIG,
      emit: (event) => eventTypes.push(event.type),
      async connectSession(value) {
        parameters = value;
        return fakeSession;
      },
    });

    await transcriber.connect();
    transcriber.sendAudio(new Uint8Array([1, 0]));
    // Let the pause Gemini needs to auto-complete the turn elapse first.
    await Bun.sleep(900);
    parameters!.callbacks.onmessage({
      serverContent: { inputTranscription: { text: "Already final." }, turnComplete: true },
    });
    transcriber.finish();

    expect(sent).toEqual([{ audio: { data: "AQA=", mimeType: "audio/pcm;rate=16000" } }]);
    expect(eventTypes).toEqual([
      "ready",
      "speech-start",
      "final",
      "speech-end",
      "complete",
    ]);
  });

  test("promotes an SDK interim hypothesis when turn completion omits final text", async () => {
    let parameters: LiveConnectParameters | undefined;
    const events: Array<{ type: string; text?: string }> = [];
    const fakeSession = {
      sendRealtimeInput() {},
      close() {},
    } as unknown as Session;
    const transcriber = new GoogleSdkLiveTranscriber({
      apiKey: "test-only",
      config: DEFAULT_TRANSCRIPTION_CONFIG,
      emit: (event) => events.push(event),
      async connectSession(value) {
        parameters = value;
        return fakeSession;
      },
    });

    await transcriber.connect();
    transcriber.sendAudio(new Uint8Array([1, 0]));
    await Bun.sleep(900);
    parameters!.callbacks.onmessage({
      serverContent: {
        interimInputTranscription: { text: "Buffered SDK words" },
        turnComplete: true,
      },
    });
    transcriber.finish();

    expect(events).toContainEqual({ type: "final", text: "Buffered SDK words" });
    expect(events.at(-1)?.type).toBe("complete");
  });

  test("does not skip SDK finalization when a late turn complete races with recent audio", async () => {
    const sent: unknown[] = [];
    let parameters: LiveConnectParameters | undefined;
    const fakeSession = {
      sendRealtimeInput(value: unknown) {
        sent.push(value);
      },
      close() {},
    } as unknown as Session;
    const events: Array<{ type: string; text?: string }> = [];
    const transcriber = new GoogleSdkLiveTranscriber({
      apiKey: "test-only",
      config: DEFAULT_TRANSCRIPTION_CONFIG,
      emit: (event) => events.push(event),
      async connectSession(value) {
        parameters = value;
        return fakeSession;
      },
    });

    await transcriber.connect();
    transcriber.sendAudio(new Uint8Array([1, 0]));
    parameters!.callbacks.onmessage({ serverContent: { turnComplete: true } });
    transcriber.finish();

    expect(sent[sent.length - 1]).toEqual({ audioStreamEnd: true });
    expect(events.some((event) => event.type === "complete")).toBe(false);

    parameters!.callbacks.onmessage({
      serverContent: { inputTranscription: { text: "Resumed speech." }, turnComplete: true },
    });
    expect(events).toContainEqual({ type: "final", text: "Resumed speech." });
    expect(events.at(-1)?.type).toBe("complete");
  });
});
