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
`.app` bundles. Add Core tests for protocol, session lifecycle, and transcript-state changes; the
dictation lifecycle (`DictationCoordinator`) is in Core so its failure paths can be tested too.
Never hit the live Gemini API in tests.

Core also builds on Linux (`./scripts/run-core-tests-linux.sh`, optionally with
`--sanitize=thread`), which is how cloud agents without a Mac verify changes. macOS CI still
builds the app target.
