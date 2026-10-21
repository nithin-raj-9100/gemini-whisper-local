# Installation instructions for an AI coding agent

Install the native macOS Gemini Whisper app for the current user. Do not ask the user to perform
terminal steps. Only macOS privacy prompts require the user's click.

1. Confirm the machine is macOS and the checkout is trusted. Never print, transmit, or commit the
   Gemini API key or `.env`. There is no auth token file in this design.
2. Check `xcode-select -p`. If unavailable, run `xcode-select --install`, ask the user to approve
   Apple's dialog, and wait until `swift` and `codesign` exist.
3. Preserve an existing `.env`; otherwise copy `.env.example` to `.env`, set mode `0600`, and have
   the user enter `GEMINI_API_KEY` without echoing it or placing it in command history.
   Alternatively the user can paste the key into **Settings → Gemini API key** after step 5.
   On first launch the app moves a `.env` key into the login Keychain; the build no longer copies
   `.env` into the app bundle.
4. From `macos/GeminiWhisper`, run `swift build`, then `./scripts/run-tests.sh`, then
   `./scripts/build-app.sh`.
5. Open the app with `open -g ../../macos/GeminiWhisper.app` (from the package directory) or
   `open -g macos/GeminiWhisper.app` from the repo root.
6. Ask the user to allow **Gemini Whisper** (`com.nithin.gemini-whisper`) under
   **System Settings → Privacy & Security → Microphone** and **Accessibility** when macOS prompts.
   These permissions must never be bypassed. The app picks up Accessibility within a few seconds
   of it being granted; no restart is needed. It also asks once to show notifications, which the
   user may allow or decline.

There is no localhost daemon or ffmpeg requirement for dictation. The user starts
dictation with Right Option (configurable in Settings) after clicking a text field.

To stop using the app, quit Gemini Whisper from the menu-bar extra. Optionally delete
`macos/GeminiWhisper.app`.
