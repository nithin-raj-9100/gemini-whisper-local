# Security policy

## Reporting

Do not open a public issue for a vulnerability. Use GitHub's private vulnerability reporting or
contact the repository owner privately.

## Local security boundary

The Gemini API key is loaded only by the Gemini Whisper app process from an untracked `.env` or the
process environment. It must never be logged, printed, or committed. Error messages redact `AIza...`
key material.

There is no localhost transcription daemon, control HTTP server, or per-user WebSocket/Bearer token.

This is a same-user desktop app. It is not designed to protect against malware already executing as
the same macOS user.

Audio is sent to Gemini 3.5 Transcribe Live. When polishing is enabled, transcript text is sent to
Gemini 3.5 Flash-Lite. Review Google's data-handling terms for the API tier attached to your key.
