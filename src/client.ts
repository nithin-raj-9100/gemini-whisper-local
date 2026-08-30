import { PcmChunker } from "./audio.ts";
import type { ServerEvent, TranscriptionConfig } from "./types.ts";

export interface LocalClientOptions {
  url: string;
  config: Partial<TranscriptionConfig>;
  onEvent?: (event: ServerEvent) => void;
}

export class LocalTranscriptionClient {
  #socket?: WebSocket;
  #chunker = new PcmChunker();
  #ready?: Promise<void>;
  #readyResolve?: () => void;
  #readyReject?: (error: Error) => void;
  #complete?: Promise<void>;
  #completeResolve?: () => void;
  #closed = false;
  #error?: Error;

  constructor(private readonly options: LocalClientOptions) {}

  connect(): Promise<void> {
    if (this.#ready) return this.#ready;
    this.#ready = new Promise((resolve, reject) => {
      this.#readyResolve = resolve;
      this.#readyReject = reject;
    });
    this.#complete = new Promise((resolve) => (this.#completeResolve = resolve));
    const socket = new WebSocket(this.options.url);
    this.#socket = socket;
    socket.binaryType = "arraybuffer";

    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ type: "start", config: this.options.config }));
    });
    socket.addEventListener("message", (message) => {
      if (typeof message.data !== "string") return;
      const event = JSON.parse(message.data) as ServerEvent;
      this.options.onEvent?.(event);
      if (event.type === "ready") this.#readyResolve?.();
      if (event.type === "complete" || event.type === "cancelled") this.#completeResolve?.();
      if (event.type === "error") {
        this.#error = new Error(`${event.code}: ${event.message}`);
        this.#closed = true;
        this.#readyReject?.(this.#error);
        this.#readyReject = undefined;
        this.#completeResolve?.();
      }
    });
    socket.addEventListener("close", () => {
      this.#closed = true;
      this.#readyReject?.(new Error("The local daemon connection closed before it became ready."));
      this.#readyReject = undefined;
      this.#completeResolve?.();
    });
    return this.#ready;
  }

  get closed(): boolean {
    return this.#closed;
  }

  get error(): Error | undefined {
    return this.#error;
  }

  sendAudio(input: Uint8Array): boolean {
    if (this.#closed || !this.#socket || this.#socket.readyState !== WebSocket.OPEN) return false;
    for (const chunk of this.#chunker.push(input)) this.#socket.send(chunk);
    return true;
  }

  finish(): Promise<void> {
    if (this.#closed) return this.#complete ?? Promise.resolve();
    const remainder = this.#chunker.flush();
    if (remainder) this.#socket?.send(remainder);
    this.#socket?.send(JSON.stringify({ type: "stop" }));
    return this.#complete ?? Promise.resolve();
  }

  close(): void {
    this.#closed = true;
    this.#socket?.close(1000, "client finished");
  }

  waitUntilDone(): Promise<void> {
    return this.#complete ?? Promise.resolve();
  }
}
