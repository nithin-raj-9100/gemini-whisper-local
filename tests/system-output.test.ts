import { describe, expect, test } from "bun:test";
import { parseMachineResult, watchMachineOutput } from "../src/system-output.ts";

describe("system output parsing", () => {
  test("parseMachineResult ignores interim, final, and polished events", () => {
    expect(parseMachineResult(JSON.stringify({ type: "interim", text: "hello" }))).toBeUndefined();
    expect(parseMachineResult(JSON.stringify({ type: "final", text: "hello world" }))).toBeUndefined();
    expect(parseMachineResult(JSON.stringify({ type: "polished", text: "Hello, world." }))).toBeUndefined();
    expect(parseMachineResult("non-json output line")).toBeUndefined();
  });

  test("parseMachineResult parses the final machine result", () => {
    const result = parseMachineResult(
      JSON.stringify({
        type: "result",
        text: "Hello, world.",
        polished: true,
        polishLatencyMs: 145,
        speculative: true,
      }),
    );
    expect(result).toEqual({
      text: "Hello, world.",
      polished: true,
      polishLatencyMs: 145,
      speculative: true,
    });
  });

  test("watchMachineOutput streams interim events to callback and resolves result", async () => {
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        const encoder = new TextEncoder();
        controller.enqueue(encoder.encode(JSON.stringify({ type: "interim", text: "first" }) + "\n"));
        controller.enqueue(encoder.encode(JSON.stringify({ type: "interim", text: "first second" }) + "\n"));
        controller.enqueue(
          encoder.encode(
            JSON.stringify({
              type: "result",
              text: "First second.",
              polished: true,
              polishLatencyMs: 120,
              speculative: false,
            }) + "\n",
          ),
        );
        controller.close();
      },
    });

    const interims: string[] = [];
    const watcher = watchMachineOutput(stream, {
      onInterim(text) {
        interims.push(text);
      },
    });

    const result = await watcher.result;
    await watcher.done;

    expect(interims).toEqual(["first", "first second"]);
    expect(result).toEqual({
      text: "First second.",
      polished: true,
      polishLatencyMs: 120,
      speculative: false,
    });
  });
});
