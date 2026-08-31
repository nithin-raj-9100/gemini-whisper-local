# gemini-whisper-local

A native macOS menu-bar app for Wispr Flow-style realtime dictation using Gemini 3.5 Transcribe Live.
Tap **Right Option** to start, speak, tap **Right Option** again to stop. Flash-Lite optionally polishes
the transcript, then the app pastes into the focused field.

The Gemini API key stays in the app process (loaded from an untracked `.env`). There is no localhost
daemon, auth token, or Bun LaunchAgent.

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

Do not grant these to Bun or “Gemini Whisper Audio”; those are the old stack.

If a previous Bun LaunchAgent is still loaded, the app boots it out on launch
(`gui/$UID/com.nithin.gemini-whisper`). Settings also has **Remove legacy Bun service**.

## Dictation

Click into a text field, then:

1. Tap Right Option (or Left Option) to begin. A HUD appears and a start sound plays.
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
- Microphone capture and paced audio-file transcription
- Right Option toggle, Escape cancel, HUD, paste/copy

Not yet included:

- App-aware writing styles
- Snippet expansion and spoken commands
- Long-running session rotation
- Transcript persistence

## License

[MIT](LICENSE)
