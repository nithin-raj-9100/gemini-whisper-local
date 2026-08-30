import { describe, expect, test } from "bun:test";
import { normalizeConfig, parseClientCommand } from "../src/protocol.ts";

describe("local protocol", () => {
  test("parses commands and applies safe defaults", () => {
    expect(parseClientCommand('{"type":"stop"}')).toEqual({ type: "stop" });
    expect(normalizeConfig()).toEqual({
      mode: "smart",
      vad: "hybrid",
      languageCodes: [],
      customVocabulary: [],
      vadPrefixPaddingMs: 300,
      vadSilenceDurationMs: 1000,
    });
  });

  test("deduplicates vocabulary and languages", () => {
    expect(
      normalizeConfig({
        languageCodes: ["en-IN", "en-IN"],
        customVocabulary: [" Gemini ", "Gemini"],
      }),
    ).toMatchObject({ languageCodes: ["en-IN"], customVocabulary: ["Gemini"] });
  });

  test("rejects malformed commands and config", () => {
    expect(() => parseClientCommand("nope")).toThrow("valid JSON");
    expect(() => parseClientCommand('{"type":"wat"}')).toThrow("Unknown command");
    expect(() => normalizeConfig({ mode: "other" as never })).toThrow("mode");
    expect(() => normalizeConfig({ languageCodes: ["not a code"] })).toThrow("BCP-47");
    expect(() => normalizeConfig({ vadPrefixPaddingMs: 2001 })).toThrow("2,000");
    expect(() => normalizeConfig({ vadSilenceDurationMs: 50 })).toThrow("5,000");
  });
});
