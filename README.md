# gemini-whisper-local

A native macOS menu-bar app for Wispr Flow-style realtime dictation using Gemini 3.5 Transcribe Live.
Tap **Right Option** to start, speak, tap **Right Option** again to stop. Or hold
**Right Option** while speaking and release to stop. Flash-Lite optionally polishes
the transcript, then the app pastes into the focused field.

The Gemini API key stays in the app process (loaded from an untracked `.env`). There is no localhost
daemon or auth token.

## Architecture

```text
Right Option
        │
        ▼
GeminiWhisper.app  ──microphone PCM16 16 kHz mono──► Gemini 3.5 Transcribe Live
        │
        ├─ interim HUD
        ├─ optional Flash-Lite polish
        └─ paste via in-process Cmd+V (or copy if focus moved)
```

## Requirements

- macOS 14+
- Xcode or Xcode Command Line Tools (`swift`, `codesign`)
- A Gemini API key with access to `gemini-3.5-transcribe-live`

`ffmpeg` is not required.

## Install with an AI coding agent

Give an agent access to the checkout and ask:

> Read `AGENT_INSTALL.md` completely and install this project on my Mac. Do not expose secrets,
> or bypass macOS permission prompts. Finish by building `macos/GeminiWhisper.app` and running
> the Swift tests.

The short, authoritative procedure is in [AGENT_INSTALL.md](AGENT_INSTALL.md). A person only needs
to enter the Gemini key privately and approve Apple's Microphone and Accessibility dialogs for
**Gemini Whisper** (`com.nithin.gemini-whisper`).

## Build and run

Put the key in an untracked `.env` (copy `.env.example`). Never commit or print `GEMINI_API_KEY`.

```bash
cd macos/GeminiWhisper
swift build
./scripts/build-app.sh
open -g ../../macos/GeminiWhisper.app
```

Or run the executable without bundling:

```bash
cd macos/GeminiWhisper
swift run --product GeminiWhisperApp
```

On first launch, grant:

1. **System Settings → Privacy & Security → Microphone** → Gemini Whisper
2. **System Settings → Privacy & Security → Accessibility** → Gemini Whisper

## Dictation

Click into a text field, then:

1. Tap Right Option to begin. A HUD appears and a start sound plays.
2. Speak. Interim text shows in the HUD.
3. Tap Right Option again to stop. The HUD switches to “Polishing with Gemini…”.
4. Finished text is pasted into the original app; the previous clipboard is restored.
   If focus moved, the transcript is copied instead.
5. Press Escape to cancel without inserting.

Sounds: Tink (start), Pop (stop / cancel / copied), Glass (pasted), Basso (error).

## Tests

Command Line Tools does not run `swift test` for this package. Use:

```bash
cd macos/GeminiWhisper
./scripts/run-tests.sh
```

That compiles `TestingInteropStub.c` into `lib_TestingInterop.dylib` (required by Command Line
Tools' Testing.framework), copies it next to the test binary, and runs
`GeminiWhisperCoreTests --testing-library swift-testing`.

## Settings

The menu-bar extra → **Settings…** controls language, vocabulary, SMART vs verbatim, polish,
VAD mode, VAD prefix/silence (defaults: manual, 500 ms prefix, 1500 ms silence), and microphone
uniqueID. `:0` in `.env` means the system default input, not an ffmpeg device index.

### Latency pipeline

Right Option key-down begins a temporary local audio buffer. A valid tap commits it to the
dictation session. Holding Right Option for 0.6 seconds also commits the buffer and keeps
recording until release; release finalizes and pastes. Using Option as a modifier cancels
the gesture without pasting. The key-down buffer does not expire while held. Capture is
paused outside dictation. Stop retains the configured audio tail, drains the converter and
sequenced PCM handoff, flushes the partial frame, then signals Gemini. No fixed audio-drain
sleep is used.

Background Flash-Lite jobs are admitted at least 4 seconds apart, with at most 6 jobs per
session. A job requires at least 12 changed/new words, or at least 4 changed/new words ending
in sentence punctuation and stable for 600 ms. Stability alone never bypasses the content gate.
Each background job makes one HTTP attempt with no retry or patch fallback. Failures impose
10 seconds of cooldown and the same failed input is not resubmitted. HTTP 429 disables all
further background jobs for that session. Stop freezes background admission; final editing
has its own request path, independent of the background budget/cooldown. This reserves local
request capacity, not a guarantee that the provider will accept the final request.
Only a candidate whose source exactly equals the current raw transcript can be inserted.
Matching in-flight work is awaited directly; stale work does not delay a final correction.
Updates receive the complete transcript and previous editing context, so late corrections
can change earlier sentences. Text is pasted once, after explicit Stop.

Hybrid mode additionally sends a turn-end hint after about 600 ms of locally detected quiet
following speech. Its energy detector never filters audio. Older pause acknowledgments are
kept separate from finalizing newer speech. Manual remains the default; evaluate Hybrid
with your microphone, quiet speech, background noise, and mid-sentence pauses before adopting it.

Optional `GEMINI_WHISPER_PATCH_EDITING=1` enables revision-scoped span edits for transcripts
of at least 160 words. It is disabled by default. Invalid revisions, duplicate/unknown span
IDs, or empty output fall back to a complete rewrite. Structural validation cannot establish
semantic accuracy; compare this mode against full rewriting before using it routinely.

Logs include audio-drain sample boundaries, polish revisions, request counts, and a final
`latency` record separating `capture_ms`, `live_ms`, `polish_wait_ms`, and `delivery_ms`.
`polish_wait_ms` is only the wait remaining after Live completion, not the full duration of
a reused background request. Outcomes distinguish fresh work, ready/in-flight reuse, and
raw fallback. Failed final polishing clears stale polish metadata.

From `macos/GeminiWhisper`, compare recent samples with:

```bash
python3 scripts/summarize-latency.py --last 6
# Filter to a particular restart using its UTC timestamp:
python3 scripts/summarize-latency.py --since 2026-09-06T17:08:21Z --last 0
```

The report includes raw fallback in overall latency and labels it separately when new timing
records are available. It excludes copy-only events. Older logs have unknown outcomes. The paste metric measures posting the shortcut, not verified
text rendering in another application. A slow Live response is no longer cut off at 1.2 seconds;
the existing 3.5-second hard fallback can still return incomplete raw text on upstream failure.
Offline tests cover orchestration, not model quality or microphone accuracy. No measured
speedup or parity with Wispr Flow is implied.

## Security

- The API key is loaded only by the app process from `.env` or the environment. It is never logged.
- There is no localhost daemon or per-user auth token.
- `.env`, `.build/`, and generated `.app` bundles are gitignored.
- This is a same-user desktop app. See [SECURITY.md](SECURITY.md).

## Current scope

Implemented:

- Realtime interim and final transcription
- SMART cleanup or verbatim transcription
- Language hint and custom vocabulary
- Automatic / hybrid / manual VAD
- Microphone capture with 100 ms realtime audio frames
- Right Option toggle, Escape cancel, HUD, paste/copy

Not yet included:

- App-aware writing styles
- Snippet expansion and spoken commands
- Long-running session rotation
- Transcript persistence

## License

[MIT](LICENSE)
