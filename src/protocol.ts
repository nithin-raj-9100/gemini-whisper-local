import {
  DEFAULT_TRANSCRIPTION_CONFIG,
  type ClientCommand,
  type TranscriptionConfig,
} from "./types.ts";

const LANGUAGE_CODE = /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/;

export class ProtocolError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "ProtocolError";
  }
}

export function parseClientCommand(raw: string): ClientCommand {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new ProtocolError("invalid_json", "Control messages must be valid JSON.");
  }

  if (!isRecord(value) || typeof value.type !== "string") {
    throw new ProtocolError("invalid_command", "A control message requires a string type.");
  }

  switch (value.type) {
    case "start":
      if (value.config !== undefined && !isRecord(value.config)) {
        throw new ProtocolError("invalid_config", "start.config must be an object.");
      }
      return { type: "start", config: value.config as Partial<TranscriptionConfig> | undefined };
    case "stop":
    case "cancel":
    case "ping":
      return { type: value.type };
    default:
      throw new ProtocolError("unknown_command", `Unknown command: ${value.type}`);
  }
}

export function normalizeConfig(input?: Partial<TranscriptionConfig>): TranscriptionConfig {
  const mode = input?.mode ?? DEFAULT_TRANSCRIPTION_CONFIG.mode;
  const vad = input?.vad ?? DEFAULT_TRANSCRIPTION_CONFIG.vad;
  const languageCodes = input?.languageCodes ?? DEFAULT_TRANSCRIPTION_CONFIG.languageCodes;
  const customVocabulary = input?.customVocabulary ?? DEFAULT_TRANSCRIPTION_CONFIG.customVocabulary;
  const vadPrefixPaddingMs =
    input?.vadPrefixPaddingMs ?? DEFAULT_TRANSCRIPTION_CONFIG.vadPrefixPaddingMs;
  const vadSilenceDurationMs =
    input?.vadSilenceDurationMs ?? DEFAULT_TRANSCRIPTION_CONFIG.vadSilenceDurationMs;

  if (mode !== "smart" && mode !== "verbatim") {
    throw new ProtocolError("invalid_mode", "mode must be smart or verbatim.");
  }
  if (vad !== "automatic" && vad !== "hybrid" && vad !== "manual") {
    throw new ProtocolError("invalid_vad", "vad must be automatic, hybrid, or manual.");
  }
  if (!Array.isArray(languageCodes) || languageCodes.length > 10) {
    throw new ProtocolError("invalid_languages", "languageCodes must contain at most 10 entries.");
  }
  if (languageCodes.some((code) => typeof code !== "string" || !LANGUAGE_CODE.test(code))) {
    throw new ProtocolError("invalid_languages", "languageCodes must contain BCP-47-like codes.");
  }
  if (!Array.isArray(customVocabulary) || customVocabulary.length > 1000) {
    throw new ProtocolError("invalid_vocabulary", "customVocabulary must contain at most 1,000 terms.");
  }
  if (
    customVocabulary.some(
      (term) => typeof term !== "string" || term.trim().length === 0 || term.length > 100,
    )
  ) {
    throw new ProtocolError(
      "invalid_vocabulary",
      "Vocabulary terms must be non-empty strings no longer than 100 characters.",
    );
  }
  if (!Number.isInteger(vadPrefixPaddingMs) || vadPrefixPaddingMs < 0 || vadPrefixPaddingMs > 2000) {
    throw new ProtocolError(
      "invalid_vad_padding",
      "vadPrefixPaddingMs must be an integer between 0 and 2,000.",
    );
  }
  if (
    !Number.isInteger(vadSilenceDurationMs) ||
    vadSilenceDurationMs < 100 ||
    vadSilenceDurationMs > 5000
  ) {
    throw new ProtocolError(
      "invalid_vad_silence",
      "vadSilenceDurationMs must be an integer between 100 and 5,000.",
    );
  }

  return {
    mode,
    vad,
    languageCodes: [...new Set(languageCodes)],
    customVocabulary: [...new Set(customVocabulary.map((term) => term.trim()))],
    vadPrefixPaddingMs,
    vadSilenceDurationMs,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
