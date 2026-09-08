# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this repository.

## Project

`gemini-whisper-local` is a native macOS menu-bar dictation app. **GeminiWhisper.app** captures
16 kHz mono PCM16 from the microphone, streams it to **Gemini 3.5 Transcribe Live**, optionally
polishes with `gemini-3.5-flash-lite`, and pastes into the focused app. Right Option toggles
dictation; Escape cancels. Not an npm package or hosted service.

Runtime: **macOS 14+**, Swift 6 package at `macos/GeminiWhisper`. The app target is
`GeminiWhisperApp`; shared protocol/Live/polish code is `GeminiWhisperCore`.

## Commands

```bash
cd macos/GeminiWhisper
swift build
./scripts/run-tests.sh
./scripts/build-app.sh   # ad-hoc signed macos/GeminiWhisper.app
swift run --product GeminiWhisperApp
```

CI (`.github/workflows/ci.yml`) runs those Swift build/test commands on macos-latest.

Environment: `GEMINI_API_KEY` (app process only), `GEMINI_WHISPER_LANGUAGE`,
`GEMINI_WHISPER_AUDIO_DEVICE` (`:0` or empty = system default input uniqueID, not ffmpeg `:N`),
`GEMINI_WHISPER_STOP_TAIL_MS`, `GEMINI_WHISPER_INTELLIGENCE_MODEL`. See `.env.example`.
Never print, transmit, or commit the API key or `.env`.

## Architecture

```text
Right Option ──► GeminiWhisper.app ──PCM16 16 kHz mono──► Gemini Live
                         │
                         ├─ HUD (interim)
                         ├─ Flash-Lite polish (optional)
                         └─ in-process Cmd+V paste / clipboard copy
```

`DictationSession` (`Sources/GeminiWhisperCore`) talks to Gemini over a hand-written WebSocket
(`GeminiLive.swift`). `DictationController` owns capture, session generation, paste, and HUD.
`MicrophoneCapture` is a persistent `AVAudioEngine` tap. `HotkeyMonitor` uses a CGEvent tap plus
NSEvent monitors for Option taps (under 0.6s toggles), holds (0.6s or longer records until
release), and Escape. Using Option as a modifier cancels that gesture without pasting.

The polish pass overlaps Live finalization (speculative Flash-Lite). If polish fails or times out,
the raw transcript is inserted. Audio is chunked to 100 ms frames (3,200 bytes). The app can
optionally register itself as a login item (`SMAppService`).

## Security boundary

The Gemini API key lives only in the app process (`.env` or environment). No localhost daemon or
WebSocket token is part of the current design. Error paths redact `AIza...` keys.
This is a same-user desktop app, not a defense against malware running as the same user.

## Testing conventions

Core tests use Swift Testing (`import Testing`) with dependency injection: `FakeWebSocket`,
`FakeTranscriber`, `ClosureHTTPClient`. Never hit the live Gemini API in tests. Command Line Tools
cannot use `swift test` here; run `./scripts/run-tests.sh` (builds `lib_TestingInterop.dylib` from
`TestingInteropStub.c`, then `GeminiWhisperCoreTests --testing-library swift-testing`).
The test target links `TestingInteropStub.c` and the script places `lib_TestingInterop.dylib` next
to the test binary so Command Line Tools' Testing.framework can load. That stub must stay out of
the app target.

## Installation

`AGENT_INSTALL.md` is the authoritative agent-facing install procedure — read it fully before
building or opening the app. Key constraints: never print, transmit, or commit `GEMINI_API_KEY` or
`.env`; require the user to approve macOS Microphone/Accessibility prompts for **Gemini Whisper**
(never bypass them).

## Out of scope (currently not implemented)

App-aware writing styles, snippet expansion/spoken commands, long-running session rotation,
transcript persistence.
