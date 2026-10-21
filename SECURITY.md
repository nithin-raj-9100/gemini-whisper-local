# Security policy

## Reporting

Do not open a public issue for a vulnerability. Use GitHub's private vulnerability reporting or
contact the repository owner privately.

## Local security boundary

The Gemini API key is stored in the user's login Keychain (or supplied through the process
environment or an untracked `.env`, which the app migrates into the Keychain) and is used only by
the Gemini Whisper app process. It is never copied into the app bundle. It must never be logged,
printed, or committed. Error messages redact `AIza...` key material.

There is no localhost transcription daemon, control HTTP server, or per-user WebSocket/Bearer token.

This is a same-user desktop app. It is not designed to protect against malware already executing as
the same macOS user.

Audio is sent to Gemini 3.5 Transcribe Live. When Live fails or its result cannot be trusted, and
when the user chooses Retry Last Dictation, the recorded audio is sent to the batch model
(Flash-Lite by default) through `generateContent`. When polishing is enabled, transcript text is
sent to Gemini 3.5 Flash-Lite. Review Google's data-handling terms for the API tier attached to
your key.

Dictation audio and recent transcripts are kept in memory only (the last three recordings, twenty
transcripts) and are discarded when the app quits. Transcripts placed on the clipboard for a paste
are marked transient so clipboard managers do not record them.
