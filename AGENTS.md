# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this repository.

## Project

`gemini-whisper-local` is a native macOS menu-bar dictation app. **GeminiWhisper.app** captures
16 kHz mono PCM16 from the microphone, streams it to **`gemini-3.5-transcribe-live`**, optionally
polishes with `gemini-3.5-flash-lite`, and pastes into the focused app. A configurable hotkey
(Right Option by default) toggles dictation; Escape cancels. Not an npm package or hosted service.

Runtime: **macOS 14+**, Swift 6 package at `macos/GeminiWhisper`. The app target is
`GeminiWhisperApp`; shared protocol/Live/polish code is `GeminiWhisperCore`.

## Commands

```bash
cd macos/GeminiWhisper
swift build
./scripts/run-tests.sh
./scripts/build-app.sh   # ad-hoc signed macos/GeminiWhisper.app
swift run --product GeminiWhisperApp
./scripts/run-core-tests-linux.sh   # Core only, with a Linux Swift toolchain (cloud containers)
```

CI (`.github/workflows/ci.yml`) runs those Swift build/test commands on macos-latest. The app
target needs AppKit; on Linux only Core builds (`--sanitize=thread` works there too).

API key: Settings → Gemini API key (login Keychain), or `GEMINI_API_KEY` in the process
environment (overrides) or `.env` (moved into the Keychain on the bundled app's first launch).
Other environment: `GEMINI_WHISPER_LANGUAGE`,
`GEMINI_WHISPER_AUDIO_DEVICE` (`:0` or empty = system default input uniqueID, not ffmpeg `:N`),
`GEMINI_WHISPER_STOP_TAIL_MS`, `GEMINI_WHISPER_INTELLIGENCE_MODEL`, `GEMINI_WHISPER_BATCH_MODEL`
(recovery transcription; defaults to the polish model), `GEMINI_WHISPER_POLISH_DEADLINE_MS` (cap on
waiting for polish after stop), `GEMINI_WHISPER_OPTIMISTIC_PASTE` (forces the paste-then-repair
Settings toggle, which is off by default). See `.env.example`.
Never print, transmit, or commit the API key or `.env`.

## Architecture

```text
Hotkey ──► GeminiWhisper.app ──PCM16 16 kHz mono──► Gemini Live
                  │   └─ every frame also recorded in memory ─► batch recovery (generateContent)
                  ├─ HUD (interim, level, errors)
                  ├─ Flash-Lite polish (optional, guarded, deadline-bound)
                  └─ in-process Cmd+V paste / clipboard copy, recent-transcript history
```

`DictationCoordinator` (Core) owns the dictation lifecycle: gestures, capture, session generation,
finalization timeouts, delivery, history, and the per-dictation `outcome` log line. It reaches the
platform only through `AudioCapturing`, `TextInserting`, and `DictationFeedback`, so it is tested in
Core. `DictationController` (app) wires it to `MicrophoneCapture`, `PasteController`, and the HUD.

`DictationSession` talks to Gemini over a hand-written WebSocket (`GeminiLive.swift`) and records
the session audio. Live transport failures never fail a dictation: Live is marked degraded,
recording continues, and at stop the recording is transcribed again (`BatchTranscription.swift`)
when Live failed, reconnected, returned nothing, or returned implausibly few words. Long dictations
rotate to a fresh Live session at a pause (or on `goAway`) before the connection limit; each Live
generation keeps its own transcript. `GeminiLiveTranscriber` serializes all state under one lock and
emits events after releasing it.

`MicrophoneCapture` is a persistent `AVAudioEngine` tap that rebuilds itself on configuration,
default-device, and device-list changes. `HotkeyMonitor` uses a CGEvent tap plus NSEvent monitors
for the configured key (`HotkeyKey`, matched by device-specific modifier bit): taps under 0.6s
toggle, holds record until release, and using the key as a modifier cancels that gesture. The event
tap retries until Accessibility is granted and is re-validated after wake; sleep interrupts a
dictation into history instead of pasting after wake.

The polish pass overlaps Live finalization (speculative Flash-Lite). `PolishGuard` rejects output
that answers the dictation or drops or invents content, and stop waits at most a length-scaled
deadline; otherwise the raw transcript is inserted. Paste restores the clipboard only if it is
unchanged and keeps the transcript there when no editable field is confirmed or the paste does
not land. Audio is chunked to 40 ms frames (1,280 bytes). The app can optionally register itself as
a login item (`SMAppService`).

## Security boundary

The Gemini API key lives in the login Keychain (or the process environment / `.env`) and only the
app process uses it; it is never copied into the app bundle. No localhost daemon or WebSocket token
is part of the current design. Error paths redact `AIza...` keys. Dictation audio is kept in memory
only (the last three recordings, for retry) and is never written to disk.
This is a same-user desktop app, not a defense against malware running as the same user.

## Testing conventions

Core tests use Swift Testing (`import Testing`) with dependency injection: `FakeWebSocket`,
`FakeTranscriber`, `ScriptedTranscriber`, `FakeBatchTranscriber`, `ClosureHTTPClient`, and the
coordinator fakes in `CoordinatorTests.swift`. Never hit the live Gemini API in tests: batch
recovery is only enabled when a test injects a batch transcriber. Command Line Tools
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

App-aware writing styles, snippet expansion/spoken commands, transcript persistence to disk
(history is in memory only), Live session resumption handles (rotation starts a fresh session).
