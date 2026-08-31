import { validatePcmChunk } from "./audio.ts";
import type { ServerEvent, TranscriptionConfig } from "./types.ts";

const GEMINI_ENDPOINT =
  "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";
const MODEL = "models/gemini-3.5-transcribe-live";
const CONNECT_TIMEOUT_MS = 15_000;
const FAST_FINISH_GRACE_MS = 1_200;
const HARD_FINISH_TIMEOUT_MS = 3_500;
const SESSION_TIMEOUT_MS = 9 * 60 * 1000;
const MAX_BUFFERED_AUDIO_BYTES = 16000 * 2 * 10;
// A turnComplete only proves the turns Gemini had already observed were
// finalized. If it arrives within RACE_WINDOW_MS of the last audio, a resumed
// turn may still be in flight, so finish() must not skip audioStreamEnd.
const RACE_WINDOW_MS = 800;
const MAX_RECONNECT_ATTEMPTS = 2;
const RECONNECT_DELAY_MS = 200;

export interface LiveTranscriber {
  connect(): Promise<void>;
  sendAudio(chunk: Uint8Array): void;
  finish(): void;
  close(): void;
}

export interface GeminiLiveOptions {
  apiKey: string;
  config: TranscriptionConfig;
  emit: (event: ServerEvent) => void;
  webSocketFactory?: (url: string) => WebSocket;
}

export function buildGeminiSetup(config: TranscriptionConfig): Record<string, unknown> {
  const setup: Record<string, unknown> = {
    model: MODEL,
    generationConfig: { responseModalities: ["TEXT"] },
    inputAudioTranscription: {
      languageCodes: config.languageCodes,
      customVocabulary: config.customVocabulary,
      mode: config.mode.toUpperCase(),
    },
  };

  if (config.vad === "manual") {
    setup.realtimeInputConfig = {
      automaticActivityDetection: { disabled: true },
    };
  } else {
    setup.realtimeInputConfig = {
      automaticActivityDetection: {
        disabled: false,
        startOfSpeechSensitivity: "START_SENSITIVITY_HIGH",
        endOfSpeechSensitivity: "END_SENSITIVITY_LOW",
        prefixPaddingMs: config.vadPrefixPaddingMs,
        silenceDurationMs: config.vadSilenceDurationMs,
      },
    };
  }

  return { setup };
}

export function parseGeminiMessage(value: unknown): ServerEvent[] {
  if (!isRecord(value)) return [];
  const events: ServerEvent[] = [];

  if ("setupComplete" in value) events.push({ type: "ready" });

  const content = isRecord(value.serverContent) ? value.serverContent : undefined;
  if (!content) return events;

  if (isRecord(content.interimInputTranscription)) {
    const text = content.interimInputTranscription.text;
    if (typeof text === "string" && text.length > 0) events.push({ type: "interim", text });
  }
  if (isRecord(content.inputTranscription)) {
    const text = content.inputTranscription.text;
    if (typeof text === "string" && text.length > 0) events.push({ type: "final", text });
  }
  if (content.turnComplete === true) events.push({ type: "complete" });
  return events;
}

export class GeminiLiveTranscriber implements LiveTranscriber {
  #socket?: WebSocket;
  #state: "idle" | "connecting" | "ready" | "finishing" | "closed" = "idle";
  #queuedAudio: Uint8Array[] = [];
  #queuedBytes = 0;
  #connectTimer?: Timer;
  #finishTimer?: Timer;
  #sessionTimer?: Timer;
  #connectResolve?: () => void;
  #connectReject?: (error: Error) => void;
  #failureReported = false;
  #reconnectAttempts = 0;
  #finishRequested = false;
  #lastAudioSentAt = 0;
  #lastTurnCompleteAt = 0;
  #latestInterim = "";
  #lastFinal = "";
  #hasTranscript = false;
  #fastFinishGraceElapsed = false;

  constructor(private readonly options: GeminiLiveOptions) {}

  connect(): Promise<void> {
    if (this.#state !== "idle") return Promise.reject(new Error("Session already started."));
    this.#state = "connecting";

    return new Promise<void>((resolve, reject) => {
      this.#connectResolve = resolve;
      this.#connectReject = reject;
      this.#openSocket();
    });
  }

  sendAudio(chunk: Uint8Array): void {
    validatePcmChunk(chunk);
    if (this.#state === "finishing" || this.#state === "closed") {
      throw new Error("Cannot send audio after the session is finishing.");
    }
    if (this.#state !== "ready") {
      if (this.#queuedBytes + chunk.byteLength > MAX_BUFFERED_AUDIO_BYTES) {
        throw new Error("Audio queue exceeded 10 seconds while Gemini was connecting.");
      }
      this.#queuedAudio.push(chunk.slice());
      this.#queuedBytes += chunk.byteLength;
      return;
    }
    this.#lastAudioSentAt = performance.now();
    this.#sendAudio(chunk);
  }

  finish(): void {
    if (this.#state === "connecting") {
      this.#finishRequested = true;
      return;
    }
    if (this.#state !== "ready") throw new Error("The transcription session is not ready.");
    this.#state = "finishing";
    this.options.emit({ type: "speech-end" });
    if (
      this.options.config.vad !== "manual" &&
      (this.#lastAudioSentAt === 0 ||
        this.#lastTurnCompleteAt - this.#lastAudioSentAt > RACE_WINDOW_MS)
    ) {
      this.options.emit({ type: "complete" });
      this.close();
      return;
    }
    const realtimeInput =
      this.options.config.vad === "manual" ? { activityEnd: {} } : { audioStreamEnd: true };
    this.#send({ realtimeInput });
    this.#finishTimer = setTimeout(() => {
      const recoveredInterim = this.#commitInterimFallback();
      if (this.#hasTranscript) {
        this.options.emit({
          type: "warning",
          code: "finalization_ack_timeout",
          message: recoveredInterim
            ? "Gemini did not acknowledge finalization; using its latest buffered transcript."
            : "Gemini did not acknowledge finalization; using the transcript already received.",
        });
        this.options.emit({ type: "complete" });
        this.close();
        return;
      }
      this.#fastFinishGraceElapsed = true;
      this.#finishTimer = setTimeout(() => {
        const lateInterim = this.#commitInterimFallback();
        if (this.#hasTranscript) {
          this.options.emit({
            type: "warning",
            code: "finalization_ack_timeout",
            message: lateInterim
              ? "Gemini did not acknowledge finalization; using its latest buffered transcript."
              : "Gemini did not acknowledge finalization; using the transcript already received.",
          });
          this.options.emit({ type: "complete" });
          this.close();
          return;
        }
        this.options.emit({
          type: "error",
          code: "final_transcript_timeout",
          message: "Gemini did not finalize the transcript in time.",
          retryable: true,
        });
        this.close();
      }, HARD_FINISH_TIMEOUT_MS - FAST_FINISH_GRACE_MS);
    }, FAST_FINISH_GRACE_MS);
  }

  close(): void {
    if (this.#state === "closed") return;
    this.#state = "closed";
    this.#clearTimers();
    const socket = this.#socket;
    if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) {
      socket.close(1000, "local session ended");
    }
  }

  #openSocket(): void {
    const url = `${GEMINI_ENDPOINT}?key=${encodeURIComponent(this.options.apiKey)}`;
    const factory = this.options.webSocketFactory ?? ((target: string) => new WebSocket(target));
    const socket = factory(url);
    this.#socket = socket;

    socket.addEventListener("open", () => {
      if (socket !== this.#socket || this.#state === "closed") return;
      socket.send(JSON.stringify(buildGeminiSetup(this.options.config)));
    });
    socket.addEventListener("message", (event) => {
      if (socket === this.#socket) this.#onMessage(event.data);
    });
    socket.addEventListener("error", () => {
      // The subsequent close event carries the metadata needed to decide
      // whether this was transient and should be reconnected.
      if (socket === this.#socket && socket.readyState !== WebSocket.CLOSED) socket.close();
    });
    socket.addEventListener("close", (event) => {
      if (socket !== this.#socket) return;
      const wasExpected = this.#state === "closed";
      const wasFinishing = this.#state === "finishing" || this.#finishRequested;
      this.#clearTimers();
      this.#socket = undefined;

      if (
        !wasExpected &&
        !wasFinishing &&
        event.code !== 1008 &&
        this.#reconnectAttempts < MAX_RECONNECT_ATTEMPTS
      ) {
        this.#reconnectAttempts++;
        this.#state = "connecting";
        this.options.emit({ type: "connecting" });
        setTimeout(() => {
          if (this.#state === "connecting") this.#openSocket();
        }, RECONNECT_DELAY_MS);
        return;
      }

      this.#state = "closed";
      if (!wasExpected && !this.#failureReported) {
        const recovered = this.#commitInterimFallback();
        if (this.#hasTranscript || recovered) {
          const reason = sanitizeCloseReason(event.reason);
          const detail = reason ? `: ${reason}` : "";
          this.options.emit({
            type: "warning",
            code: "gemini_connection_closed",
            message: `Gemini Live closed the session (code ${event.code})${detail}; using buffered transcript.`,
          });
          this.options.emit({ type: "complete" });
          return;
        }
        const reason = sanitizeCloseReason(event.reason);
        const detail = reason ? `: ${reason}` : "";
        this.#fail(
          "gemini_connection_closed",
          `Gemini Live closed the session (code ${event.code})${detail}.`,
          event.code !== 1008,
        );
      }
    });

    this.#connectTimer = setTimeout(() => {
      if (socket === this.#socket) socket.close();
    }, CONNECT_TIMEOUT_MS);
  }

  #onMessage(data: string | ArrayBuffer | Blob): void {
    void decodeWebSocketData(data)
      .then((text) => JSON.parse(text) as unknown)
      .then((message) => {
        for (const event of parseGeminiMessage(message)) {
          if (event.type === "ready") {
            this.#onReady();
            this.options.emit(event);
            this.options.emit({ type: "speech-start" });
            continue;
          }
          if (event.type === "complete") {
            this.#commitInterimFallback();
            this.#lastTurnCompleteAt = performance.now();
            // Gemini completes a turn whenever automatic VAD observes a natural
            // pause. A dictation may contain many such turns, so only expose
            // session completion after the local client explicitly called finish().
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
          if (
            event.type === "interim" &&
            this.#state === "finishing" &&
            this.#fastFinishGraceElapsed &&
            this.#commitInterimFallback()
          ) {
            this.options.emit({
              type: "warning",
              code: "finalization_ack_timeout",
              message: "Gemini did not acknowledge finalization; using its latest buffered transcript.",
            });
            this.options.emit({ type: "complete" });
            this.close();
            continue;
          }
          if (event.type === "final" && this.#state === "finishing") {
            this.options.emit({ type: "complete" });
            this.close();
          }
        }
      })
      .catch(() => {
        this.#fail("invalid_gemini_message", "Gemini returned an unreadable message.", true);
        this.close();
      });
  }

  #onReady(): void {
    if (this.#state !== "connecting") return;
    if (this.#connectTimer) clearTimeout(this.#connectTimer);
    this.#state = "ready";
    this.#connectResolve?.();
    this.#connectResolve = undefined;
    this.#connectReject = undefined;

    if (this.options.config.vad === "manual") this.#send({ realtimeInput: { activityStart: {} } });
    for (const chunk of this.#queuedAudio) this.#sendAudio(chunk);
    if (this.#queuedAudio.length > 0) this.#lastAudioSentAt = performance.now();
    this.#queuedAudio = [];
    this.#queuedBytes = 0;

    this.#sessionTimer = setTimeout(() => {
      this.options.emit({
        type: "error",
        code: "session_limit",
        message: "The local session reached its nine-minute safety limit.",
        retryable: true,
      });
      this.close();
    }, SESSION_TIMEOUT_MS);

    if (this.#finishRequested) {
      this.#finishRequested = false;
      this.finish();
    }
  }

  #sendAudio(chunk: Uint8Array): void {
    this.#send({
      realtimeInput: {
        audio: {
          data: chunk.toBase64(),
          mimeType: "audio/pcm;rate=16000",
        },
      },
    });
  }

  #send(message: Record<string, unknown>): void {
    if (!this.#socket || this.#socket.readyState !== WebSocket.OPEN) {
      throw new Error("Gemini Live socket is not open.");
    }
    this.#socket.send(JSON.stringify(message));
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

  #fail(code: string, message: string, retryable: boolean): void {
    if (this.#failureReported) return;
    this.#failureReported = true;
    const error = new Error(message);
    this.#connectReject?.(error);
    this.#connectResolve = undefined;
    this.#connectReject = undefined;
    this.options.emit({ type: "error", code, message, retryable });
  }

  #clearTimers(): void {
    if (this.#connectTimer) clearTimeout(this.#connectTimer);
    if (this.#finishTimer) clearTimeout(this.#finishTimer);
    if (this.#sessionTimer) clearTimeout(this.#sessionTimer);
  }
}

async function decodeWebSocketData(data: string | ArrayBuffer | Blob): Promise<string> {
  if (typeof data === "string") return data;
  if (data instanceof Blob) return data.text();
  return new TextDecoder().decode(data);
}

function sanitizeCloseReason(reason: string): string {
  return reason.replace(/AIza[\w-]+/g, "[redacted]").slice(0, 240);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizeTranscript(text: string): string {
  return text.replace(/\s+/g, " ").trim().toLocaleLowerCase();
}
