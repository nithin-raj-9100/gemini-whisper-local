# Installation instructions for an AI coding agent

Install this project for the current macOS user. Do not ask the user to perform terminal steps.
Only macOS privacy prompts and Apple's installer UI require the user's click.

1. Confirm the machine is macOS and the checkout is trusted. Never print, transmit, or commit the
   Gemini API key, `.env`, or `~/.config/gemini-whisper-local/auth-token`.
2. Check `command -v bun`. If Bun is absent, ask permission to download it from the official
   `https://bun.sh` installer, install it, and refresh `PATH`.
3. Check `xcode-select -p`. If unavailable, run `xcode-select --install`, ask the user to approve
   Apple's dialog, and wait until `swiftc` and `codesign` exist.
4. Check `/Applications/Karabiner-Elements.app`. If absent, ask permission to download the current
   signed installer from `https://karabiner-elements.pqrs.org`, run it, and ask the user to approve
   its macOS prompts. Do not assume Homebrew exists.
5. Run `bun install --frozen-lockfile`. Preserve an existing `.env`; otherwise copy `.env.example`
   to `.env`, set mode `0600`, and have the user enter `GEMINI_API_KEY` without echoing it or placing
   it in command history.
6. Run `bun test`, then `bun run install:macos`. The installer generates machine-specific
   LaunchAgent and Karabiner configuration, creates a mode-`0600` local auth token, builds/signs the
   AVAudioEngine helper, and starts the service.
7. Ask the user to allow `Gemini Whisper Audio` under Microphone and Bun under Accessibility when
   macOS prompts. These permissions must never be bypassed.
8. Run `bun run doctor:macos`. Finish only when all required checks pass and
   `http://127.0.0.1:8766/health` reports healthy.

`ffmpeg` is optional: do not install it for system-wide dictation. It is needed only for standalone
`mic`, `file`, and `devices` commands. Clipboard insertion uses stock AppleScript and does not
require `pbcopy` or `pbpaste`; the doctor reports those tools as optional when present.

To remove the installation, run `bun run uninstall:macos`. Add `--purge` only when the user also
asks to delete the local authentication token.
