# Installation instructions for an AI coding agent

Install the native macOS Gemini Whisper app for the current user. Do not ask the user to perform
terminal steps. Only macOS privacy prompts require the user's click.

1. Confirm the machine is macOS and the checkout is trusted. Never print, transmit, or commit the
   Gemini API key or `.env`. There is no auth token file in this design.
2. Check `xcode-select -p`. If unavailable, run `xcode-select --install`, ask the user to approve
   Apple's dialog, and wait until `swift` and `codesign` exist.
3. Preserve an existing `.env`; otherwise copy `.env.example` to `.env`, set mode `0600`, and have
   the user enter `GEMINI_API_KEY` without echoing it or placing it in command history.
4. From `macos/GeminiWhisper`, run `swift build`, then `./scripts/run-tests.sh`, then
   `./scripts/build-app.sh`.
5. Open the app with `open -g ../../macos/GeminiWhisper.app` (from the package directory) or
   `open -g macos/GeminiWhisper.app` from the repo root.
6. Ask the user to allow **Gemini Whisper** (`com.nithin.gemini-whisper`) under
   **System Settings → Privacy & Security → Microphone** and **Accessibility** when macOS prompts.
   These permissions must never be bypassed.

There is no localhost daemon or ffmpeg requirement for dictation. The user starts
dictation with Right Option after clicking a text field.

To stop using the app, quit Gemini Whisper from the menu-bar extra. Optionally delete
`macos/GeminiWhisper.app`.
