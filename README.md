# gemini-whisper-local

A native macOS menu-bar app for Wispr Flow-style realtime dictation using Gemini 3.5 Transcribe Live.
Tap **Right Option** to start, speak, tap **Right Option** again to stop. Or hold
**Right Option** while speaking and release to stop. The key is configurable in Settings.
Flash-Lite optionally polishes the transcript, then the app pastes into the focused field.

A dictation is never silently lost: the audio is recorded while it streams, and if Live drops,
reconnects, or returns nothing, the recording is transcribed again when you stop. Recent
transcripts (and the last few recordings) stay available from the menu bar.

The Gemini API key is stored in your login Keychain (or the environment / an untracked `.env`) and
used only by the app process. There is no localhost daemon or auth token.

## Architecture

```text
Hotkey (Right Option by default)
        │
        ▼
GeminiWhisper.app  ──microphone PCM16 16 kHz mono──► Gemini 3.5 Transcribe Live
        │   └─ recorded in memory ──► batch transcription when Live cannot be trusted
        ├─ interim HUD with input level
        ├─ optional Flash-Lite polish (checked against the raw text, time-bounded)
        └─ paste via in-process Cmd+V (clipboard kept when delivery is uncertain)
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

Enter the key in **Settings → Gemini API key** (saved to the login Keychain), or put it in an
untracked `.env` (copy `.env.example`); the bundled app moves a `.env` key into the Keychain on
first launch. Never commit or print `GEMINI_API_KEY`.

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

1. Tap Right Option to begin. A HUD appears and a start sound plays; the bar next to the
   status shows the microphone level.
2. Speak. Interim text shows in the HUD.
3. Tap Right Option again to stop. The HUD switches to “Polishing with Gemini…”.
4. Finished text is pasted into the focused app. Your previous clipboard comes back about
   1.5 seconds later, unless you copied something new in the meantime.
5. Press Escape to cancel without inserting. The text stays in **Recent Transcripts**.

When delivery is uncertain the transcript stays on the clipboard so ⌘V recovers it: no editable
field could be confirmed through Accessibility, Secure Input is active, or the focused field did
not change after the paste (you are notified). Password fields are never typed into.

Recovery, from the menu bar:

- **Copy Last Transcript** / **Paste Last Transcript**
- **Retry Last Dictation from Audio** transcribes the last kept recording again (after a failed,
  empty, cancelled, or interrupted dictation)
- **Recent Transcripts** lists this session's dictations; choose one to copy it

History lives in memory only and is cleared when the app quits. Closing the lid mid-dictation
keeps it in history instead of pasting after wake.

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

The dictation lifecycle lives in `GeminiWhisperCore` (`DictationCoordinator`) behind small
capture, insertion, and feedback protocols, so failure paths are tested without a Mac: socket
drops, reconnect overflow, rotation, polish guard and deadline, back-to-back dictations, paste
fallbacks, and recovery. With a Linux Swift toolchain:

```bash
cd macos/GeminiWhisper
./scripts/run-core-tests-linux.sh                       # Core build + tests
./scripts/run-core-tests-linux.sh --sanitize=thread     # with ThreadSanitizer
```

## Settings

The menu-bar extra → **Settings…** controls the API key, the dictation key (Right/Left Option,
Right Command, Right Control, Right Shift, or Fn/Globe), language, vocabulary, SMART vs verbatim,
polish, VAD mode, VAD prefix/silence (defaults: manual, 500 ms prefix, 1500 ms silence), and
microphone uniqueID. `:0` in `.env` means the system default input, not an ffmpeg device index.
Plugging in or removing a headset, or changing the system default input, is picked up mid-session.

### Reliability

- **Live failures do not lose speech.** Every frame is recorded in memory while it streams. If Live
  errors, overflows its reconnect buffer, reconnects mid-dictation, returns nothing although
  speech was captured, or returns implausibly few words for the speech captured, the recording is
  transcribed with `generateContent` (inline WAV, split at pauses into ≤4-minute chunks) when you
  stop. Only a rejected API key stops a dictation early.
- **Long dictations** hand over to a fresh Live session at a natural pause after 7 minutes
  (or when Gemini sends `goAway`), finishing the old session gracefully, instead of hitting the
  connection limit.
- **Reconnects** back off exponentially and wait for a network route instead of spending their
  attempts while offline.
- **Merging** keeps genuinely repeated or parallel sentences: a final is only dropped as a resend
  when it repeats the tail of the transcript and no new speech audio could explain it.
- **Polish** is rejected when it answers the dictation, adds an assistant preamble, or drops or
  invents most of the content, and stop waits at most 2.5 s plus 15 ms per word (8 s cap) before
  inserting the raw transcript.
- **Paste then repair** (Settings, off by default) inserts the raw text first and replaces it
  only after Accessibility confirms that exact text is still in front of the cursor.

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

Logs include audio-drain sample boundaries, polish revisions, request counts, a final
`latency` record separating `capture_ms`, `live_ms`, `polish_wait_ms`, and `delivery_ms`, and one
`outcome` line per dictation (`result=inserted|copied|empty|failed|cancelled|interrupted`, the
transcript source, any batch recovery reason, audio and voiced milliseconds, reconnects, and
rotations). The log rotates at 5 MB.
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
records are available. Its `reliability` section counts delivered, recovered-to-clipboard,
failed (audio kept for retry), empty, and abandoned dictations, the delivered rate, batch
recoveries by reason, and stop-to-paste p50/p95. It excludes copy-only events. Older logs have unknown outcomes. The paste metric measures posting the shortcut, not verified
text rendering in another application. A slow Live response is no longer cut off at 1.2 seconds;
the existing 3.5-second hard fallback can still return incomplete raw text on upstream failure.
Offline tests cover orchestration, not model quality or microphone accuracy. No measured
speedup or parity with Wispr Flow is implied.

## Security

- The API key is read only by the app process, from the login Keychain, the environment, or `.env`.
  It is never logged and never copied into the app bundle.
- Dictation audio is held in memory (the last three recordings, for retry) and never written to disk.
- There is no localhost daemon or per-user auth token.
- `.env`, `.build/`, and generated `.app` bundles are gitignored.
- This is a same-user desktop app. See [SECURITY.md](SECURITY.md).

## Current scope

Implemented:

- Realtime interim and final transcription
- SMART cleanup or verbatim transcription
- Language hint and custom vocabulary
- Automatic / hybrid / manual VAD
- Microphone capture with 40 ms realtime audio frames, following device changes
- Configurable hotkey toggle/hold, Escape cancel, HUD, paste/copy
- Recording-based recovery, Live session rotation, in-memory transcript history

Not yet included:

- App-aware writing styles
- Snippet expansion and spoken commands
- Transcript persistence across launches
- Live session resumption handles (rotation starts a fresh session)

## License

[MIT](LICENSE)
