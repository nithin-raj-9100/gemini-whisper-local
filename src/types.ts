export type TranscriptionMode = "smart" | "verbatim";
export type VadMode = "automatic" | "hybrid" | "manual";

export interface TranscriptionConfig {
  mode: TranscriptionMode;
  polish: boolean;
  languageCodes: string[];
  customVocabulary: string[];
  vad: VadMode;
  vadPrefixPaddingMs: number;
  vadSilenceDurationMs: number;
}

export type ClientCommand =
  | { type: "start"; config?: Partial<TranscriptionConfig> }
  | { type: "stop" }
  | { type: "cancel" }
  | { type: "ping" };

export type ServerEvent =
  | { type: "hello"; protocol: 1; audio: AudioContract }
  | { type: "connecting" }
  | { type: "ready" }
  | { type: "speech-start" }
  | { type: "speech-end" }
  | { type: "interim"; text: string }
  | { type: "final"; text: string }
  | { type: "polished"; text: string; model: string; latencyMs: number; speculative?: boolean }
  | { type: "warning"; code: string; message: string }
  | { type: "complete" }
  | { type: "cancelled" }
  | { type: "pong" }
  | { type: "error"; code: string; message: string; retryable: boolean };

export interface AudioContract {
  encoding: "pcm_s16le";
  sampleRate: 16000;
  channels: 1;
  chunkMilliseconds: 100;
}

export const AUDIO_CONTRACT: AudioContract = {
  encoding: "pcm_s16le",
  sampleRate: 16000,
  channels: 1,
  chunkMilliseconds: 100,
};

export const DEFAULT_TRANSCRIPTION_CONFIG: TranscriptionConfig = {
  mode: "smart",
  polish: true,
  languageCodes: [],
  customVocabulary: [],
  vad: "hybrid",
  vadPrefixPaddingMs: 300,
  vadSilenceDurationMs: 1000,
};
