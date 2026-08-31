export type MachineResult = {
  text: string;
  polished: boolean;
  polishLatencyMs: number;
  speculative: boolean;
};

export function watchMachineOutput(
  stream: ReadableStream<Uint8Array>,
  options?: { onInterim?: (text: string) => void },
): {
  result: Promise<MachineResult | undefined>;
  done: Promise<void>;
} {
  let resolveResult!: (result: MachineResult | undefined) => void;
  let resolved = false;
  const result = new Promise<MachineResult | undefined>((resolve) => (resolveResult = resolve));
  const done = (async () => {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let pending = "";
    try {
      while (true) {
        const { done, value } = await reader.read();
        pending += decoder.decode(value, { stream: !done });
        const lines = pending.split("\n");
        pending = lines.pop() ?? "";
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          try {
            const msg = JSON.parse(trimmed) as { type?: unknown; text?: unknown };
            if ((msg.type === "interim" || msg.type === "final") && typeof msg.text === "string") {
              options?.onInterim?.(msg.text);
            }
          } catch {}
          const parsed = parseMachineResult(trimmed);
          if (parsed && !resolved) {
            resolved = true;
            resolveResult(parsed);
          }
        }
        if (done) break;
      }
      const parsed = parseMachineResult(pending);
      if (parsed && !resolved) {
        resolved = true;
        resolveResult(parsed);
      }
    } finally {
      reader.releaseLock();
      if (!resolved) resolveResult(undefined);
    }
  })();
  return { result, done };
}

export function parseMachineResult(output: string): MachineResult | undefined {
  const line = output.trim().split("\n").at(-1);
  if (!line) return undefined;
  try {
    const value = JSON.parse(line) as {
      type?: unknown;
      text?: unknown;
      polished?: unknown;
      polishLatencyMs?: unknown;
      speculative?: unknown;
    };
    if (typeof value.text !== "string") return undefined;
    if (value.type === "interim" || value.type === "final" || value.type === "polished") {
      return undefined;
    }
    return {
      text: value.text,
      polished: value.polished === true,
      polishLatencyMs:
        typeof value.polishLatencyMs === "number" ? Math.round(value.polishLatencyMs) : 0,
      speculative: value.speculative === true,
    };
  } catch {
    return undefined;
  }
}
