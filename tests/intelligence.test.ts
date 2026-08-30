import { describe, expect, test } from "bun:test";
import { createTranscriptIntelligence } from "../src/intelligence.ts";

describe("transcript intelligence", () => {
  test("uses Flash-Lite with minimal thinking and returns only model text", async () => {
    let requestUrl = "";
    let requestInit: RequestInit | undefined;
    const intelligence = createTranscriptIntelligence({
      apiKey: "test-only",
      fetcher: (async (input: string | URL | Request, init?: RequestInit) => {
        requestUrl = String(input);
        requestInit = init;
        return Response.json({
          candidates: [{ content: { parts: [{ text: "1. Milk\n2. Vegetables" }] } }],
        });
      }) as typeof fetch,
    });

    const result = await intelligence.polish("number one milk number two vegetables");
    const body = JSON.parse(String(requestInit?.body)) as {
      systemInstruction: { parts: Array<{ text: string }> };
      generationConfig: { thinkingConfig: { thinkingLevel: string; includeThoughts: boolean } };
    };

    expect(requestUrl).toContain("/gemini-3.5-flash-lite:generateContent");
    expect(requestUrl).not.toContain("test-only");
    expect(new Headers(requestInit?.headers).get("x-goog-api-key")).toBe("test-only");
    expect(body.generationConfig.thinkingConfig).toEqual({
      thinkingLevel: "MINIMAL",
      includeThoughts: false,
    });
    expect(body.systemInstruction.parts[0]?.text).toContain("ALWAYS format the items");
    expect(result.text).toBe("1. Milk\n2. Vegetables");
    expect(result.model).toBe("gemini-3.5-flash-lite");
  });

  test("retries a transient socket failure once", async () => {
    let attempts = 0;
    const intelligence = createTranscriptIntelligence({
      apiKey: "test-only",
      fetcher: (async () => {
        attempts++;
        if (attempts === 1) throw new TypeError("The socket connection was closed unexpectedly.");
        return Response.json({
          candidates: [{ content: { parts: [{ text: "Recovered text" }] } }],
        });
      }) as typeof fetch,
    });

    const result = await intelligence.polish("raw text");
    expect(attempts).toBe(2);
    expect(result.text).toBe("Recovered text");
  });
});
