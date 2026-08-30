# Contributing

Use Bun 1.4 or newer. Keep the default path headless, local-first in architecture, and compatible
with the native Bun WebSocket implementation.

```bash
bun install --frozen-lockfile
bun test
bun run check
```

Do not commit API keys, `.env`, auth tokens, recordings, transcripts, logs, dependencies, generated
app bundles, or machine-specific LaunchAgents. Add tests for protocol, authentication, lifecycle,
and transcript-state changes. Open an issue before introducing a graphical application, hosted
service, account system, or required third-party runtime dependency.
