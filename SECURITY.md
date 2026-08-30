# Security policy

## Reporting

Do not open a public issue for a vulnerability. Use GitHub's private vulnerability reporting or
contact the repository owner privately.

## Local security boundary

The daemon binds to loopback and requires a randomly generated per-user token for control and
transcription endpoints. Browser-origin requests are rejected. The token is stored at
`~/.config/gemini-whisper-local/auth-token` with mode `0600` and must never be logged or committed.

This protects against cross-origin webpages and accidental local clients. It is not designed to
protect against malware already executing as the same macOS user.

Audio is sent to Gemini 3.5 Transcribe Live. When polishing is enabled, transcript text is sent to
Gemini 3.5 Flash-Lite. Review Google's data-handling terms for the API tier attached to your key.
