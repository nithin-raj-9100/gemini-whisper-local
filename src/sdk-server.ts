import { GoogleSdkLiveTranscriber } from "./google-sdk-live.ts";
import { createDaemon, type DaemonOptions } from "./server.ts";

export function createSdkDaemon(
  options: Pick<DaemonOptions, "speculativeIntelligence" | "warmConfig"> = {},
) {
  const apiKey = Bun.env.GEMINI_API_KEY;
  return createDaemon({
    apiKey,
    hostname: Bun.env.GEMINI_WHISPER_HOST,
    port: Bun.env.GEMINI_WHISPER_PORT ? Number(Bun.env.GEMINI_WHISPER_PORT) : undefined,
    sessionFactory(config, emit) {
      if (!apiKey) throw new Error("GEMINI_API_KEY is required for the SDK daemon.");
      return new GoogleSdkLiveTranscriber({ apiKey, config, emit });
    },
    label: "google-sdk",
    ...options,
  });
}
