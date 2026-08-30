import { bearerAuthorization, ensureLocalAuthToken } from "./local-auth.ts";

const port = Bun.env.GEMINI_WHISPER_HOTKEY_PORT ?? "8766";

try {
  const token = await ensureLocalAuthToken();
  const response = await fetch(`http://127.0.0.1:${port}/toggle`, {
    method: "POST",
    headers: { Authorization: bearerAuthorization(token) },
  });
  if (!response.ok) throw new Error(`background service returned HTTP ${response.status}`);
} catch (error) {
  const message = error instanceof Error ? error.message : "unknown error";
  console.error(`gemini-whisper background service is unavailable: ${message}`);
  process.exit(1);
}
