# Contributing

Use macOS 14+ with Swift 6 / Xcode Command Line Tools. Keep dictation local-first: the API key
stays in the app process, and there is no hosted service or localhost daemon.

```bash
cd macos/GeminiWhisper
swift build
./scripts/run-tests.sh
./scripts/build-app.sh
```

Do not commit API keys, `.env`, recordings, transcripts, logs, `.build/` output, or generated
`.app` bundles. Add Core tests for protocol, session lifecycle, and transcript-state changes.
Never hit the live Gemini API in tests.
