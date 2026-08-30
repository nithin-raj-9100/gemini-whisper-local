import {
  AudioTranscriptionConfigMode,
  EndSensitivity,
  GoogleGenAI,
  Modality,
  StartSensitivity,
  type LiveConnectConfig,
  type LiveConnectParameters,
  type LiveServerMessage,
  type Session,
} from "@google/genai/web";
import { validatePcmChunk } from "./audio.ts";
import type { LiveTranscriber } from "./gemini-live.ts";
import type { ServerEvent, TranscriptionConfig } from "./types.ts";

const MODEL = "gemini-3.5-transcribe-live";
const MAX_BUFFERED_AUDIO_BYTES = 16000 * 2 * 10;
const MAX_RECONNECT_ATTEMPTS = 2;
const RECONNECT_DELAY_MS = 200;
const FINISH_TIMEOUT_MS = 2_500;
const SESSION_TIMEOUT_MS = 9 * 60 * 1000;

type ConnectSdkSession = (params: LiveConnectParameters) => Promise<Session>;

export interface GoogleSdkLiveOptions {
  apiKey: string;
  config: TranscriptionConfig;
  emit: (event: ServerEvent) => void;
  connectSession?: ConnectSdkSession;
}

export function buildSdkLiveConfig(config: TranscriptionConfig): LiveConnectConfig {
  return {
    responseModalities: [Modality.TEXT],
    inputAudioTranscription: {
      languageCodes: config.languageCodes,
      customVocabulary: config.customVocabulary,
      mode:
        config.mode === "smart"
          ? AudioTranscriptionConfigMode.SMART
          : AudioTranscriptionConfigMode.VERBATIM,
    },
    realtimeInputConfig: {
      automaticActivityDetection:
        config.vad === "manual"
          ? { disabled: true }
          : {
              disabled: false,
              startOfSpeechSensitivity: StartSensitivity.START_SENSITIVITY_HIGH,
              endOfSpeechSensitivity: EndSensitivity.END_SENSITIVITY_LOW,
              prefixPaddingMs: config.vadPrefixPaddingMs,
              silenceDurationMs: config.vadSilenceDurationMs,
            },
    },
  };
}

export function sdkMessageToEvents(message: LiveServerMessage): ServerEvent[] {
  const content = message.serverContent;
  if (!content) return [];
  const events: ServerEvent[] = [];
  const interim = content.interimInputTranscription?.text;
  const final = content.inputTranscription?.text;
  if (interim) events.push({ type: "interim", text: interim });
  if (final) events.push({ type: "final", text: final });
  if (content.turnComplete) events.push({ type: "complete" });
  return events;
}

export class GoogleSdkLiveTranscriber implements LiveTranscriber {
  #session?: Session;
  #state: "idle" | "connecting" | "ready" | "finishing" | "closed" = "idle";
  #generation = 0;
  #reconnectAttempts = 0;
  #queuedAudio: Uint8Array[] = [];
  #queuedBytes = 0;
  #finishRequested = false;
  #failureReported = false;
  #finishTimer?: Timer;
  #sessionTimer?: Timer;
  #connectResolve?: () => void;
  #connectReject?: (error: Error) => void;
  #audioSinceTurnComplete = false;
  #latestInterim = "";
  #lastFinal = "";
  #hasTranscript = false;

  constructor(private readonly options: GoogleSdkLiveOptions) {}

  connect(): Promise<void> {
    if (this.#state !== "idle") return Promise.reject(new Error("Session already started."));
    this.#state = "connecting";
    const result = new Promise<void>((resolve, reject) => {
      this.#connectResolve = resolve;
      this.#connectReject = reject;
    });
    void this.#openSession();
    return result;
  }

  sendAudio(chunk: Uint8Array): void {
    validatePcmChunk(chunk);
    if (this.#state === "closed" || this.#state === "finishing") {
      throw new Error("Cannot send audio after the SDK session is finishing.");
    }
    if (this.#state !== "ready" || !this.#session) {
      if (this.#queuedBytes + chunk.byteLength > MAX_BUFFERED_AUDIO_BYTES) {
        throw new Error("Audio queue exceeded 10 seconds while the SDK was connecting.");
      }
      this.#queuedAudio.push(chunk.slice());
      this.#queuedBytes += chunk.byteLength;
      return;
    }
    this.#audioSinceTurnComplete = true;
    this.#sendAudio(chunk);
  }

  finish(): void {
    if (this.#state === "connecting") {
      this.#finishRequested = true;
      return;
    }
    if (this.#state !== "ready" || !this.#session) {
      throw new Error("The SDK transcription session is not ready.");
    }
    this.#state = "finishing";
    this.options.emit({ type: "speech-end" });
    if (this.options.config.vad !== "manual" && !this.#audioSinceTurnComplete) {
      this.options.emit({ type: "complete" });
      this.close();
      return;
    }
    if (this.options.config.vad === "manual") {
      this.#session.sendRealtimeInput({ activityEnd: {} });
    } else {
      this.#session.sendRealtimeInput({ audioStreamEnd: true });
    }
    this.#finishTimer = setTimeout(() => {
      const recoveredInterim = this.#commitInterimFallback();
      if (this.#hasTranscript) {
        this.options.emit({
          type: "warning",
          code: "finalization_ack_timeout",
          message: recoveredInterim
            ? "The Google SDK did not acknowledge finalization; using its latest buffered transcript."
            : "The Google SDK did not acknowledge finalization; using the transcript already received.",
        });
        this.options.emit({ type: "complete" });
        this.close();
        return;
      }
      this.#fail(
        "final_transcript_timeout",
        "The Google SDK did not finalize the transcript in time.",
        true,
      );
      this.close();
    }, FINISH_TIMEOUT_MS);
  }

  close(): void {
    if (this.#state === "closed") return;
    this.#state = "closed";
    this.#generation++;
    this.#clearTimers();
    this.#session?.close();
    this.#session = undefined;
  }

  async #openSession(): Promise<void> {
    const generation = ++this.#generation;
    const sdkClient = this.options.connectSession
      ? undefined
      : new GoogleGenAI({ apiKey: this.options.apiKey });
    const connectSession =
      this.options.connectSession ?? sdkClient!.live.connect.bind(sdkClient!.live);

    try {
      const session = await connectSession({
        model: MODEL,
        config: buildSdkLiveConfig(this.options.config),
        callbacks: {
          onmessage: (message) => {
            if (generation === this.#generation) this.#onMessage(message);
          },
          onerror: () => {
            if (generation === this.#generation) this.#handleDisconnect("SDK WebSocket error.");
          },
          onclose: (event) => {
            if (generation === this.#generation && this.#state !== "closed") {
              this.#handleDisconnect(
                `SDK WebSocket closed with code ${event.code}${event.reason ? `: ${event.reason}` : ""}.`,
              );
            }
          },
        },
      });

      if (generation !== this.#generation || this.#state === "closed") {
        session.close();
        return;
      }
      this.#session = session;
      this.#state = "ready";
      this.#connectResolve?.();
      this.#connectResolve = undefined;
      this.#connectReject = undefined;
      this.options.emit({ type: "ready" });

      if (this.options.config.vad === "manual") {
        session.sendRealtimeInput({ activityStart: {} });
      }
      this.options.emit({ type: "speech-start" });
      for (const chunk of this.#queuedAudio) this.#sendAudio(chunk);
      if (this.#queuedAudio.length > 0) this.#audioSinceTurnComplete = true;
      this.#queuedAudio = [];
      this.#queuedBytes = 0;

      this.#sessionTimer = setTimeout(() => {
        this.#fail("session_limit", "The SDK session reached its nine-minute safety limit.", true);
        this.close();
      }, SESSION_TIMEOUT_MS);

      if (this.#finishRequested) {
        this.#finishRequested = false;
        this.finish();
      }
    } catch (error) {
      if (generation !== this.#generation || this.#state === "closed") return;
      this.#handleDisconnect(safeSdkError(error));
    }
  }

  #onMessage(message: LiveServerMessage): void {
    for (const event of sdkMessageToEvents(message)) {
      if (event.type === "complete") {
        this.#commitInterimFallback();
        this.#audioSinceTurnComplete = false;
        if (this.#state === "finishing") {
          this.options.emit(event);
          this.close();
        }
        continue;
      }
      if (event.type === "interim") this.#latestInterim = event.text;
      if (event.type === "final") {
        this.#latestInterim = "";
        this.#lastFinal = event.text;
        this.#hasTranscript = true;
      }
      this.options.emit(event);
      if (event.type === "final" && this.#state === "finishing") {
        this.options.emit({ type: "complete" });
        this.close();
      }
    }
  }

  #sendAudio(chunk: Uint8Array): void {
    this.#session?.sendRealtimeInput({
      audio: { data: chunk.toBase64(), mimeType: "audio/pcm;rate=16000" },
    });
  }

  #commitInterimFallback(): boolean {
    const text = this.#latestInterim.trim();
    this.#latestInterim = "";
    if (!text || normalizeTranscript(text) === normalizeTranscript(this.#lastFinal)) return false;
    this.#lastFinal = text;
    this.#hasTranscript = true;
    this.options.emit({ type: "final", text });
    return true;
  }

  #handleDisconnect(message: string): void {
    if (this.#state === "closed") return;
    const wasFinishing = this.#state === "finishing" || this.#finishRequested;
    const previousSession = this.#session;
    this.#generation++;
    this.#clearTimers();
    this.#session = undefined;
    previousSession?.close();

    if (!wasFinishing && this.#reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
      this.#reconnectAttempts++;
      this.#state = "connecting";
      this.options.emit({ type: "connecting" });
      setTimeout(() => {
        if (this.#state === "connecting") void this.#openSession();
      }, RECONNECT_DELAY_MS);
      return;
    }

    this.#state = "closed";
    this.#fail("gemini_sdk_connection_closed", message, true);
  }

  #fail(code: string, message: string, retryable: boolean): void {
    if (this.#failureReported) return;
    this.#failureReported = true;
    this.#connectReject?.(new Error(message));
    this.#connectResolve = undefined;
    this.#connectReject = undefined;
    this.options.emit({ type: "error", code, message, retryable });
  }

  #clearTimers(): void {
    if (this.#finishTimer) clearTimeout(this.#finishTimer);
    if (this.#sessionTimer) clearTimeout(this.#sessionTimer);
  }
}

function safeSdkError(error: unknown): string {
  if (!(error instanceof Error)) return "Google SDK connection failed.";
  return error.message.replace(/AIza[\w-]+/g, "[redacted]").slice(0, 240);
}

function normalizeTranscript(text: string): string {
  return text.replace(/\s+/g, " ").trim().toLocaleLowerCase();
}
