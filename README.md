# gemini-whisper-local

A local, headless experiment for Wispr Flow-style realtime dictation using Gemini 3.5 Transcribe Live. It is intentionally not an npm package, hosted service, or desktop application.

The raw transport has no runtime dependencies and uses Bun 1.4's native HTTP/WebSocket server,
native WebSocket client, process spawning, environment loading, and test runner. A side-by-side
variant uses the official `@google/genai` SDK, installed and locked with Bun. The system-wide
macOS path uses a small signed AVAudioEngine helper; `ffmpeg` remains an optional executable for
the standalone `mic`, `file`, and `devices` commands.

The SDK transport imports the SDK's official `@google/genai/web` build. This preserves the Google
SDK's Live session/config/message layer while routing its WebSocket traffic through Bun's native
global `WebSocket`; the SDK's Node-only `ws` implementation is not loaded at runtime.

## Architecture

```text
microphone or audio file
        │ PCM16, 16 kHz, mono
        ▼
Bun CLI ──local WebSocket──► Bun daemon ──native WebSocket──► Gemini Live
        ◄──── interim/final transcript events ────────────────┘
```

The daemon binds to `127.0.0.1` by default. The Gemini API key stays in the daemon process; local clients never receive it.

## Requirements

- Bun 1.4+
- `ffmpeg` for the standalone `mic`, `file`, and `devices` commands
- A Gemini API key with access to `gemini-3.5-transcribe-live`
- macOS system mode: Xcode Command Line Tools and Karabiner-Elements

## Install with an AI coding agent

Give an agent access to the checkout and ask:

> Read `AGENT_INSTALL.md` completely and install this project on my Mac. Do not expose secrets,
> assume Homebrew or ffmpeg exists, or bypass macOS permission prompts. Finish by running the
> project tests and `bun run doctor:macos`.

The short, authoritative procedure is in [AGENT_INSTALL.md](AGENT_INSTALL.md). The agent checks and
installs missing prerequisites, preserves an existing `.env`, generates machine-specific service
configuration, and verifies the result. A person only needs to enter the Gemini key privately and
approve Apple's Microphone, Accessibility, developer-tools, or signed-installer dialogs.

## Run locally

For development without the system service, install dependencies, put the key in an untracked
`.env`, and run one daemon:

```bash
bun install --frozen-lockfile
bun run serve
```

Choose exactly one upstream transport:

```bash
# Hand-written Gemini WebSocket protocol
bun run serve

# Official Google Gen AI SDK, same local API and clients
bun run serve:sdk
```

Both bind to the same port, so stop one before starting the other.

## System-wide macOS dictation

The installed user LaunchAgent runs one Bun process containing both the localhost transcription
daemon and the right-Option controller. It keeps the signed AVAudioEngine capture helper warm while
idle, eliminating microphone setup from the hot path. Gemini Live connects when dictation starts,
while you are speaking, rather than occupying the provider's limited concurrent-session quota while
idle. Karabiner-Elements maps a tap of right Option to the controller while preserving right Option
as a modifier when it is held with another key.

Click into a text field in Chrome, VS Code, Terminal, or another macOS application, then:

1. Tap right Option to begin dictating.
2. Tap right Option again to stop and polish.
3. The finished text is pasted into the original focused application and the previous clipboard is
   restored. If focus moved to another application, the transcript is copied instead of pasted.

The service plays a short sound when capture starts, when finalization begins, after successful
insertion, or when an error occurs. Right Option is therefore usable without opening a status UI.

The agent-facing installer builds and ad-hoc signs the microphone helper, generates a protected
local auth token, writes the LaunchAgent using the actual checkout and Bun paths, installs the
Karabiner rule, and starts the service:

```bash
bun run install:macos
bun run doctor:macos
```

Allow `Gemini Whisper Audio` under **System Settings → Privacy & Security → Microphone**. Allow the
installed Bun executable under **Privacy & Security → Accessibility**, because insertion uses
System Events to paste into the focused application.

System-wide dictation does not require ffmpeg. The installer reports it as optional because only
the standalone `mic`, `file`, and `devices` commands use it. Uninstall with
`bun run uninstall:macos`; add `--purge` only to remove the per-user auth token too.

The LaunchAgent is installed at `~/Library/LaunchAgents/com.nithin.gemini-whisper.plist` and starts
automatically at login. Logs are written to `~/Library/Logs/gemini-whisper.log` and
`~/Library/Logs/gemini-whisper.error.log`. The service reads the existing project `.env`; set
`GEMINI_WHISPER_TRANSPORT=sdk` there to use the Google SDK over Bun's native WebSocket, or leave it
unset/`native` for the lower-overhead raw transport.

Manual service controls:

```bash
launchctl kickstart -k gui/$(id -u)/com.nithin.gemini-whisper
launchctl bootout gui/$(id -u)/com.nithin.gemini-whisper
```

In another terminal, inspect microphone device identifiers:

```bash
bun run devices
```

Start microphone dictation and press Enter to stop:

```bash
bun run mic --device :0 --language en-IN \
  --vocabulary "Bun,Gemini,Nithin"
```

Or stream an existing audio file in real time:

```bash
bun run file ./sample.m4a --language en-IN
```

Use `--verbatim` to preserve filler words and false starts; it also disables Flash-Lite polishing.
Use `--no-polish` to keep SMART transcription while skipping the second model call.

The microphone CLI uses manual activity boundaries by default: Gemini receives `activityStart`
before microphone capture and `activityEnd` when Enter is pressed. This keeps natural pauses inside
one dictation and prevents the first words after a pause from being clipped. Use `--automatic-vad`
to split turns at pauses; its defaults are high speech-start sensitivity, 300 ms prefix padding,
low speech-end sensitivity, and a 1,000 ms silence threshold. Tune it with
`--prefix-padding-ms` and `--silence-ms`.

## Local WebSocket protocol

Connect to `ws://127.0.0.1:8765/v1/transcribe` using the WebSocket subprotocol
`gemini-whisper-v1.<token>`. Native clients read the mode-`0600` token from
`~/.config/gemini-whisper-local/auth-token`; browser-origin handshakes are rejected. The server
first emits `hello`. Start a Gemini session with:

```json
{
  "type": "start",
  "config": {
    "mode": "smart",
    "polish": true,
    "vad": "hybrid",
    "languageCodes": [],
    "customVocabulary": ["Bun", "Gemini"]
  }
}
```

Wait for `ready`, then send binary raw PCM frames: signed 16-bit little-endian, 16 kHz, mono. The recommended chunk size is 3,200 bytes (100 ms). Send `{"type":"stop"}` at the end.

The daemon emits `interim`, `final`, `complete`, and structured `error` events. Send `cancel` to discard a session or `ping` for a liveness check.

The daemon sends the accumulated text through `gemini-3.5-flash-lite` with minimal thinking. On
the system path it starts this second call from the latest hypothesis at the stop edge, concurrently
with Live finalization. A changed final transcript aborts and replaces the stale cleanup request.
The terminal keeps showing raw live transcription, then prints one `polished` result with corrected
prose and spoken-list formatting before `complete`.
If this optional cleanup fails or exceeds its eight-second timeout, the daemon emits a warning and
still completes with the raw transcript intact. Override the cleanup model with
`GEMINI_WHISPER_INTELLIGENCE_MODEL`.

When Gemini returns transcript text but omits the final `audioStreamEnd` acknowledgement, the live
transport waits 2.5 seconds, promotes the latest buffered hypothesis if necessary, and continues to
polishing instead of failing the dictation.

## Raw versus SDK experiment

The microphone and file commands are transport-independent. Run one daemon, dictate the same
phrase, stop it, then run the other daemon and repeat. The raw implementation lives in
`src/gemini-live.ts`; the official SDK adapter lives in `src/google-sdk-live.ts`. Both implement
the same `LiveTranscriber` interface and share all local protocol, PCM, VAD, and CLI code.

## Verification

```bash
bun test
bun run check
curl http://127.0.0.1:8765/health
curl http://127.0.0.1:8766/health
```

## Security

- The API key is loaded only by the local daemon and is never sent to local WebSocket clients.
- Both local servers bind to `127.0.0.1`; do not expose them through a public proxy.
- State-changing HTTP routes require a bearer token; WebSockets require the matching authenticated
  subprotocol. Browser `Origin` requests are rejected and connection rates are bounded.
- The installer stores the random token at `~/.config/gemini-whisper-local/auth-token` with mode
  `0600`. It must never be logged, shared, or committed.
- `.env`, dependencies, build output, logs, and the generated signed app bundle are gitignored.
- This boundary protects against webpages and accidental clients, not malware already running as
  the same macOS user. See [SECURITY.md](SECURITY.md).

Measure the actual stop-to-polished path with a PCM16, mono, 16 kHz WAV. The warmup and trials are
paced by 20 seconds by default to avoid exhausting Gemini Live session-rate quota:

```bash
bun run benchmark:latency ./sample.wav 10
```

The benchmark separately reports total stop-to-complete latency, Flash-Lite latency, successful
polish responses, and whether cleanup was overlapped with Live finalization.

## Current scope

Implemented core behavior:

- Realtime interim and final transcription
- SMART cleanup or verbatim transcription
- Automatic language detection or an explicit language hint
- Custom vocabulary biasing
- Automatic/hybrid/manual VAD configuration
- Bounded pre-connection audio buffering
- Two automatic retries for unexpected Gemini WebSocket closures, with audio buffered during reconnect
- Nine-minute safety cutoff before Gemini's ten-minute session limit
- Microphone and audio-file producers
- Authenticated, rate-limited loopback control and transcription APIs
- Agent-driven macOS install, uninstall, and diagnostics
- A documented, provider-independent localhost protocol

Not yet included:

- App-aware writing styles
- Snippet expansion and spoken commands
- Long-running session rotation
- Transcript persistence

Those are separate layers on top of the transcription core.

## License

[MIT](LICENSE)
