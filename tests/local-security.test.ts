import { describe, expect, test } from "bun:test";
import {
  bearerAuthorization,
  requestHasBearerToken,
  requestHasWebSocketToken,
  websocketAuthProtocol,
} from "../src/local-auth.ts";
import { SlidingWindowRateLimiter } from "../src/rate-limit.ts";
import { createDaemon } from "../src/server.ts";

const TOKEN = "b".repeat(64);

describe("local security boundary", () => {
  test("requires exact bearer and WebSocket credentials", () => {
    expect(
      requestHasBearerToken(
        new Request("http://127.0.0.1/toggle", {
          headers: { Authorization: bearerAuthorization(TOKEN) },
        }),
        TOKEN,
      ),
    ).toBe(true);
    expect(requestHasBearerToken(new Request("http://127.0.0.1/toggle"), TOKEN)).toBe(false);
    expect(
      requestHasWebSocketToken(
        new Request("http://127.0.0.1/v1/transcribe", {
          headers: { "Sec-WebSocket-Protocol": websocketAuthProtocol(TOKEN) },
        }),
        TOKEN,
      ),
    ).toBe(true);
  });

  test("rejects unauthenticated and browser-origin transcription requests", async () => {
    const server = createDaemon({
      authToken: TOKEN,
      apiKey: "test-only",
      port: 0,
      quiet: true,
      intelligence: false,
      sessionFactory() {
        throw new Error("The rejected request must not create an upstream session.");
      },
    });
    try {
      const url = `http://127.0.0.1:${server.port}/v1/transcribe`;
      expect((await fetch(url)).status).toBe(401);
      expect(
        (
          await fetch(url, {
            headers: {
              Origin: "https://malicious.example",
              "Sec-WebSocket-Protocol": websocketAuthProtocol(TOKEN),
            },
          })
        ).status,
      ).toBe(403);
    } finally {
      server.stop(true);
    }
  });

  test("bounds accepted actions within a sliding window", () => {
    const limiter = new SlidingWindowRateLimiter(2, 1_000);
    expect(limiter.accept(1_000)).toBe(true);
    expect(limiter.accept(1_001)).toBe(true);
    expect(limiter.accept(1_500)).toBe(false);
    expect(limiter.accept(2_001)).toBe(true);
  });
});
