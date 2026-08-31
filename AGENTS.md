# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`gemini-whisper-local` is a local, headless, Wispr-Flow-style realtime dictation tool. A Bun daemon on `127.0.0.1` receives 16 kHz mono PCM16 microphone/audio-file streams over a local WebSocket and streams them to **Gemini 3.5 Transcribe Live**, which returns interim/final transcripts. A second Gemini call (`gemini-3.5-flash-lite`) optionally polishes the final text before insertion. Not an npm package, hosted service, or desktop app.

Runtime: **Bun >= 1.4** (`package.json` engines). Imports use explicit `.ts` extensions (`tsconfig.json` `allowImportingTsExtensions`). No linter is configured.

## Commands

```bash
bun install --frozen-lockfile   # deps (only @google/genai is a package dep)
bun test                        # all tests (Bun test runner, no framework)
bun test tests/server.test.ts   # single test file
bun test -t "speculative"       # filter by test name
bun run check                   # type/build check (bun build src/cli.ts)
bun run serve                   # daemon, raw WebSocket transport   (port 8765)
bun run serve:sdk               # daemon, @google/genai SDK transport (port 8765)
bun run mic --device :0         # live mic client (needs ffmpeg)
bun run file ./sample.m4a       # stream an audio file (needs ffmpeg)
bun run devices                 # list ffmpeg capture devices
bun run install:macos           # system-mode installer (LaunchAgent + Swift helper)
bun run doctor:macos            # verify system-mode install
bun run uninstall:macos         # remove system mode (--purge also deletes auth token)
bun run benchmark:latency ./sample.wav 10   # stop→polished latency (20s paced)
```

CI (`.github/workflows/ci.yml`) runs `bun test` + `bun run check` on ubuntu-latest and macos-latest with Bun 1.4.0.

Environment: `GEMINI_API_KEY` (daemon-only), `GEMINI_WHISPER_HOST`/`_PORT` (default `127.0.0.1:8765`), `_HOTKEY_PORT` (8766), `_AUDIO_DEVICE` (`:0`), `_LANGUAGE`, `_TRANSPORT` (`native`|`sdk`), `_AUTH_TOKEN_FILE`, `_INTELLIGENCE_MODEL`. See `.env.example`.

## Architecture

Data flow:

```text
mic / file ──ffmpeg PCM16 16kHz mono──► LocalTranscriptionClient ──local WS──► Bun daemon ──WS──► Gemini Live
client ◄─────────── interim / final / polished / complete ◄──────────────────────┘
```

### The `LiveTranscriber` seam — two interchangeable upstream transports

`cli.ts` and the daemon are transport-independent. `server.ts` (`createDaemon`) takes a `sessionFactory(config, emit)`; the default constructs a `GeminiLiveTranscriber` (`gemini-live.ts`), and `sdk-server.ts` (`createSdkDaemon`) injects a `GoogleSdkLiveTranscriber` (`google-sdk-live.ts`). Both implement the same `LiveTranscriber` interface (`connect/sendAudio/finish/close`) from `gemini-live.ts`, and both speak to **the same local protocol and clients**. `bun run serve` vs `serve:sdk` is purely an A/B test of raw hand-written WebSocket protocol vs the official Google SDK. The SDK build uses `@google/genai/web` so its Node-only `ws` is never loaded — traffic still rides Bun's native `WebSocket`. Both daemons bind port 8765, so only one runs at a time.

### The daemon (`server.ts`)

One `Bun.serve` with a `/v1/transcribe` WebSocket endpoint plus `/health`. Per-socket state machine: `idle → connecting → ready → finishing → closed`. Flow: server sends `hello` → client sends `start {config}` → `connecting` → `ready` → client sends binary PCM → `interim`/`final` events → client sends `stop` → (optional polish) → `polished` → `complete`. Wire types and config validation live in `types.ts` / `protocol.ts` (`normalizeConfig` enforces every field). Binary messages are raw PCM only — the client must await `ready` (server rejects audio before then). Audio is chunked to 100 ms frames (3,200 bytes) by `PcmChunker` (`audio.ts`); that contract is declared in the `hello` event.

Warm-session optimization for the system path: the daemon can keep a pre-connected Gemini session (`warmConfig`) so a dictation starts without connect latency; it's consumed and replenished on use.

### The polish pass (two model calls)

Transcripts accumulate in `finalSegments`/`latestInterim`. On `stop`, `server.ts` may fire a **speculative** polish: it starts the Flash-Lite cleanup (`intelligence.ts`, `createTranscriptIntelligence`) from the latest hypothesis *before* asking Live to finalize, overlapping the two round trips. If the final transcript differs from the speculative draft, the speculative request is aborted and re-run (`transcriptsCompatible` decides reuse). If polish fails or times out (8 s), the daemon emits `warning` and completes with the raw transcript. `GeminiLiveTranscriber`/`GoogleSdkLiveTranscriber` handle Gemini's own finalization: if `audioStreamEnd` gets no `turnComplete` ack within ~2.5 s, the latest interim hypothesis is promoted to a `final` and the session completes instead of failing.

### System-wide macOS mode (`system-service.ts` + `scripts/macos.ts` + Swift helper)

A user LaunchAgent runs `src/system-service.ts` — one Bun process that hosts the transcription daemon (port 8765) *and* a control HTTP server (port 8766, bearer-token auth: `/toggle`, `/permissions`, `/audio-check`, `/health`). It keeps a signed `AVAudioEngine` helper (`macos/GeminiWhisperAudio.app`, source `macos/audio-helper/main.swift`) running persistently over localhost sockets: the helper captures 16 kHz PCM, detects a lone right-Option tap via native event taps (preserving right-Option-as-modifier), and sends `toggle`. The controller then spawns `bun run src/cli.ts mic --system` as a child per dictation; the child streams audio relayed from the helper into the transcription daemon and prints a **single JSON line** on stdout (`{text, polished, polishLatencyMs, speculative}`). The controller parses that line, pastes via AppleScript System Events (restoring the prior clipboard), plays sound cues, and handles errors/quota messages. If focus moved away, it copies instead. Right Option also triggers via a legacy `system-trigger.ts` one-shot toggle.

### Security boundary

The Gemini API key lives only in the daemon process; clients never receive it. Both servers bind `127.0.0.1`. WebSocket auth is `Sec-WebSocket-Protocol: gemini-whisper-v1.<64-hex-token>`; HTTP routes use the same token as a Bearer header; browser `Origin` handshakes are rejected; connections and control calls are rate-limited (`rate-limit.ts`). The token is a random 64-hex value in `~/.config/gemini-whisper-local/auth-token` (mode 0600) or `GEMINI_WHISPER_AUTH_TOKEN`, managed by `local-auth.ts`. `.env`, `dist/`, logs, and the signed app bundle are gitignored. Error paths redact `AIza...` API keys. This boundary protects against webpages/accidental clients, not same-user malware.

## Testing conventions

Tests import real modules (no mocking framework) and use dependency injection instead: `webSocketFactory` (FakeWebSocket in `gemini-live.test.ts`), `sessionFactory` (`server.test.ts` inlines a `FakeTranscriber`), `fetcher` (`intelligence.test.ts`), `connectSession` (`google-sdk-live.test.ts`). `server.test.ts` and `local-security.test.ts` spin up the real daemon on port 0 and drive it with a real `WebSocket` + a 64-char token. Keep this pattern: never hit the live Gemini API in tests.

## Installation

`AGENT_INSTALL.md` is the authoritative agent-facing install procedure — read it fully before running `bun run install:macos`. Key constraints: never print, transmit, or commit `GEMINI_API_KEY`, `.env`, or the auth token; preserve an existing `.env`; require the user to approve macOS Microphone/Accessibility prompts (never bypass them); `ffmpeg` is optional and only for the standalone `mic`/`file`/`devices` commands. `scripts/macos.ts` generates the LaunchAgent plist using the live checkout/Bun paths, builds and ad-hoc signs the Swift helper (`bun run system:audio:build`), and `doctor` verifies every required check plus the 8766 health endpoint.

## Out of scope (currently not implemented)

App-aware writing styles, snippet expansion/spoken commands, long-running session rotation, transcript persistence.
