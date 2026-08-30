import { GeminiLiveTranscriber, type LiveTranscriber } from "./gemini-live.ts";
import { createTranscriptIntelligence, type TranscriptIntelligence } from "./intelligence.ts";
import { requestHasWebSocketToken, websocketAuthProtocol } from "./local-auth.ts";
import { ProtocolError, normalizeConfig, parseClientCommand } from "./protocol.ts";
import { SlidingWindowRateLimiter } from "./rate-limit.ts";
import { AUDIO_CONTRACT, type ServerEvent, type TranscriptionConfig } from "./types.ts";

const MAX_AUDIO_MESSAGE_BYTES = 1024 * 1024;

interface SocketData {
  id: string;
  session?: LiveTranscriber;
  finalSegments: string[];
  latestInterim: string;
  polishEnabled: boolean;
  speculativePolish?: {
    input: string;
    startedBeforeFinal: boolean;
    controller: AbortController;
    result: Promise<
      | { ok: true; value: Awaited<ReturnType<TranscriptIntelligence["polish"]>> }
      | { ok: false; error: unknown }
    >;
  };
  speculativeTimer?: Timer;
  state: "idle" | "connecting" | "ready" | "finishing" | "closed";
}

export interface DaemonOptions {
  authToken: string;
  apiKey?: string;
  hostname?: string;
  port?: number;
  sessionFactory?: (
    config: TranscriptionConfig,
    emit: (event: ServerEvent) => void,
  ) => LiveTranscriber;
  quiet?: boolean;
  label?: string;
  intelligence?: TranscriptIntelligence | false;
  speculativeIntelligence?: boolean;
  warmConfig?: TranscriptionConfig;
}

export function createDaemon(options: DaemonOptions) {
  if (!options.authToken) throw new Error("A local authentication token is required.");
  const hostname = options.hostname ?? "127.0.0.1";
  const port = options.port ?? 8765;
  const apiKey = options.apiKey ?? Bun.env.GEMINI_API_KEY;
  const intelligence =
    options.intelligence === false
      ? undefined
      : options.intelligence ?? (apiKey ? createTranscriptIntelligence({ apiKey }) : undefined);
  const connectionRate = new SlidingWindowRateLimiter(30, 60_000);
  const createSession = (
    config: TranscriptionConfig,
    emit: (event: ServerEvent) => void,
  ): LiveTranscriber => {
    if (options.sessionFactory) return options.sessionFactory(config, emit);
    if (!apiKey) throw new Error("GEMINI_API_KEY is required for Gemini Live.");
    return new GeminiLiveTranscriber({ apiKey, config, emit });
  };
  let warmSession =
    apiKey && options.warmConfig ? createWarmSession(options.warmConfig, createSession) : undefined;
  const replenishWarmSession = () => {
    if (!warmSession && apiKey && options.warmConfig) {
      warmSession = createWarmSession(options.warmConfig, createSession);
    }
  };

  const acquireSession = (
    config: TranscriptionConfig,
    emit: (event: ServerEvent) => void,
  ): LiveTranscriber => {
    if (warmSession && sameConfig(warmSession.config, config)) {
      const ready = warmSession.take(emit, replenishWarmSession);
      warmSession = undefined;
      return ready;
    }
    return createSession(config, emit);
  };

  const server = Bun.serve({
    hostname,
    port,
    routes: {
      "/": () =>
        Response.json({
          name: "gemini-whisper-local",
          websocket: "/v1/transcribe",
          health: "/health",
        }),
      "/health": () =>
        Response.json({
          ok: true,
          runtime: `Bun ${Bun.version}`,
          geminiKeyConfigured: Boolean(apiKey),
          activeWebSockets: server.pendingWebSockets,
        }),
    },
    fetch(request, bunServer) {
      const url = new URL(request.url);
      if (url.pathname !== "/v1/transcribe") return new Response("Not found", { status: 404 });
      if (request.headers.has("origin")) {
        return new Response("Browser WebSocket origins are not allowed", { status: 403 });
      }
      if (!requestHasWebSocketToken(request, options.authToken)) {
        return new Response("Unauthorized", { status: 401 });
      }
      if (!connectionRate.accept() || server.pendingWebSockets >= 4) {
        return new Response("Too many local transcription sessions", {
          status: 429,
          headers: { "Retry-After": "2" },
        });
      }
      const upgraded = bunServer.upgrade(request, {
        headers: { "Sec-WebSocket-Protocol": websocketAuthProtocol(options.authToken) },
        data: {
          id: crypto.randomUUID(),
          state: "idle",
          finalSegments: [],
          latestInterim: "",
          polishEnabled: true,
        } satisfies SocketData,
      });
      return upgraded ? undefined : new Response("WebSocket upgrade failed", { status: 400 });
    },
    websocket: {
      data: {} as SocketData,
      maxPayloadLength: MAX_AUDIO_MESSAGE_BYTES,
      idleTimeout: 120,
      open(ws) {
        send(ws, { type: "hello", protocol: 1, audio: AUDIO_CONTRACT });
      },
      async message(ws, message) {
        try {
          if (typeof message !== "string") {
            if (ws.data.state !== "ready" && ws.data.state !== "connecting") {
              throw new ProtocolError("not_ready", "Wait for the ready event before sending audio.");
            }
            const chunk = new Uint8Array(message.buffer, message.byteOffset, message.byteLength);
            ws.data.session?.sendAudio(chunk);
            return;
          }

          const command = parseClientCommand(message);
          if (command.type === "ping") {
            send(ws, { type: "pong" });
            return;
          }
          if (command.type === "cancel") {
            ws.data.session?.close();
            ws.data.session = undefined;
            ws.data.state = "closed";
            send(ws, { type: "cancelled" });
            return;
          }
          if (command.type === "stop") {
            if (ws.data.state !== "ready" && ws.data.state !== "connecting") {
              throw new ProtocolError("not_ready", "There is no ready transcription to stop.");
            }
            ws.data.state = "finishing";
            if (ws.data.polishEnabled && options.speculativeIntelligence && intelligence) {
              // Start cleanup from the latest hypothesis before asking Live to
              // finalize. This overlaps the two provider round trips. If Live
              // revises the text, startSpeculativePolish aborts and replaces
              // this request when the final transcript arrives.
              startSpeculativePolish(ws.data, intelligence, false, true);
            }
            ws.data.session?.finish();
            return;
          }

          if (ws.data.state !== "idle") {
            throw new ProtocolError("already_started", "This connection already has a session.");
          }
          if (!apiKey) {
            throw new ProtocolError(
              "missing_api_key",
              "Set GEMINI_API_KEY in the daemon environment before starting a transcription.",
            );
          }

          const config = normalizeConfig(command.config);
          ws.data.polishEnabled = config.polish;
          ws.data.state = "connecting";
          send(ws, { type: "connecting" });

          const emit = (event: ServerEvent) => {
            if (event.type === "connecting") ws.data.state = "connecting";
            if (event.type === "ready") ws.data.state = "ready";
            if (event.type === "interim") ws.data.latestInterim = event.text;
            if (event.type === "final") {
              ws.data.latestInterim = "";
              ws.data.finalSegments.push(event.text);
              if (ws.data.polishEnabled && ws.data.state === "finishing" && intelligence) {
                startSpeculativePolish(ws.data, intelligence, true);
              }
            }
            if (event.type === "complete") {
              if (ws.data.speculativeTimer) clearTimeout(ws.data.speculativeTimer);
              if (ws.data.polishEnabled && options.speculativeIntelligence && intelligence) {
                startSpeculativePolish(ws.data, intelligence, true);
              }
              void finishWithIntelligence(ws, ws.data.polishEnabled ? intelligence : undefined);
              return;
            }
            if (event.type === "cancelled" || event.type === "error") {
              ws.data.state = "closed";
            }
            send(ws, event);
            if (event.type === "error") ws.close(1011, "upstream transcription failed");
          };
          ws.data.session = acquireSession(config, emit);
          // LiveTranscriber reports connection failures through its event stream.
          // Swallow the rejected setup promise here to avoid emitting a second,
          // less useful internal_error after the provider-specific error.
          await ws.data.session.connect().catch(() => undefined);
        } catch (error) {
          const protocolError = error instanceof ProtocolError ? error : undefined;
          send(ws, {
            type: "error",
            code: protocolError?.code ?? "internal_error",
            message: protocolError?.message ?? safeErrorMessage(error),
            retryable: false,
          });
        }
      },
      close(ws) {
        if (ws.data.speculativeTimer) clearTimeout(ws.data.speculativeTimer);
        ws.data.state = "closed";
        ws.data.session?.close();
        ws.data.session = undefined;
      },
      error(ws) {
        ws.data.session?.close();
      },
    },
  });

  if (!options.quiet) {
    console.log(
      `gemini-whisper ${options.label ?? "raw-websocket"} daemon listening at http://${server.hostname}:${server.port}`,
    );
    console.log(apiKey ? "Gemini API key loaded." : "Gemini API key is not configured.");
  }
  return server;
}

function startSpeculativePolish(
  data: SocketData,
  intelligence: TranscriptIntelligence,
  replaceIfChanged = false,
  startedBeforeFinal = false,
): void {
  if (data.speculativeTimer) clearTimeout(data.speculativeTimer);
  data.speculativeTimer = undefined;
  const draft = transcriptDraft(data);
  if (!draft) return;
  if (data.speculativePolish) {
    if (!replaceIfChanged || transcriptsCompatible(data.speculativePolish.input, draft)) return;
    data.speculativePolish.controller.abort("Final transcript replaced speculative draft.");
  }
  const controller = new AbortController();
  data.speculativePolish = {
    input: draft,
    startedBeforeFinal,
    controller,
    result: intelligence.polish(draft, { signal: controller.signal }).then(
      (value) => ({ ok: true as const, value }),
      (error) => ({ ok: false as const, error }),
    ),
  };
}

interface WarmSession {
  config: TranscriptionConfig;
  take(emit: (event: ServerEvent) => void, onReleased: () => void): LiveTranscriber;
}

function createWarmSession(
  config: TranscriptionConfig,
  factory: (config: TranscriptionConfig, emit: (event: ServerEvent) => void) => LiveTranscriber,
): WarmSession {
  let target: ((event: ServerEvent) => void) | undefined;
  const buffered: ServerEvent[] = [];
  const session = factory(config, (event) => {
    if (target) target(event);
    else buffered.push(event);
  });
  const connected = session.connect();
  void connected.catch(() => undefined);
  let taken = false;

  return {
    config,
    take(emit, onReleased) {
      if (taken) throw new Error("Warm Gemini session was already consumed.");
      taken = true;
      return {
        async connect() {
          target = emit;
          for (const event of buffered.splice(0)) emit(event);
          await connected;
        },
        sendAudio(chunk) {
          session.sendAudio(chunk);
        },
        finish() {
          session.finish();
        },
        close() {
          session.close();
          onReleased();
        },
      };
    },
  };
}

function sameConfig(left: TranscriptionConfig, right: TranscriptionConfig): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

async function finishWithIntelligence(
  ws: Bun.ServerWebSocket<SocketData>,
  intelligence: TranscriptIntelligence | undefined,
): Promise<void> {
  if (ws.data.state === "closed") return;
  ws.data.state = "finishing";
  const transcript = ws.data.finalSegments.join("\n").trim();

  if (intelligence && transcript) {
    try {
      const speculative = ws.data.speculativePolish;
      const speculativeResult = speculative ? await speculative.result : undefined;
      const reusedSpeculative = Boolean(
        speculative &&
          speculativeResult?.ok &&
          transcriptsCompatible(speculative.input, transcript),
      );
      const result =
        reusedSpeculative && speculativeResult?.ok
          ? speculativeResult.value
          : await intelligence.polish(transcript);
      send(ws, {
        type: "polished",
        ...result,
        ...(reusedSpeculative && speculative?.startedBeforeFinal ? { speculative: true } : {}),
      });
    } catch (error) {
      send(ws, {
        type: "warning",
        code: "intelligence_failed",
        message: safeErrorMessage(error),
      });
    }
  }

  ws.data.state = "closed";
  send(ws, { type: "complete" });
}

function transcriptDraft(data: SocketData): string {
  return [...data.finalSegments, data.latestInterim].filter(Boolean).join("\n").trim();
}

function transcriptsCompatible(draft: string, final: string): boolean {
  const left = normalizeForComparison(draft);
  const right = normalizeForComparison(final);
  if (!left || !right) return false;
  if (left === right) return true;
  const leftWords = left.split(" ");
  const rightWords = right.split(" ");
  const length = Math.max(leftWords.length, rightWords.length);
  let matching = 0;
  for (let index = 0; index < Math.min(leftWords.length, rightWords.length); index++) {
    if (leftWords[index] === rightWords[index]) matching++;
  }
  return matching / length >= 0.9 && Math.abs(left.length - right.length) <= 32;
}

function normalizeForComparison(text: string): string {
  return text.toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

function send(ws: Bun.ServerWebSocket<SocketData>, event: ServerEvent): void {
  if (ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify(event));
}

function safeErrorMessage(error: unknown): string {
  if (!(error instanceof Error)) return "Unexpected local error.";
  return error.message.replace(/AIza[\w-]+/g, "[redacted]").slice(0, 240);
}
