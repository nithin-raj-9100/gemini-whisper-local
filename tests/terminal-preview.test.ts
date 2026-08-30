import { describe, expect, test } from "bun:test";
import { TerminalPreview } from "../src/terminal-preview.ts";

describe("TerminalPreview", () => {
  test("replaces an interactive preview from its measured origin", () => {
    const writes: string[] = [];
    const preview = new TerminalPreview((text) => writes.push(text), true);

    preview.update("A long first hypothesis that may wrap");
    preview.update("A corrected cumulative hypothesis");
    preview.commit("The final transcript.");

    expect(writes).toEqual([
      "A long first hypothesis that may wrap",
      "\r",
      "\x1b[J",
      "A corrected cumulative hypothesis",
      "\r",
      "\x1b[J",
      "The final transcript.\n",
    ]);
  });

  test("retains carriage-return output when stdout is not interactive", () => {
    const writes: string[] = [];
    const preview = new TerminalPreview((text) => writes.push(text), false);
    preview.update("partial");
    preview.commit("final");
    expect(writes).toEqual(["\r\x1b[2Kpartial", "final\n"]);
  });

  test("bounds a cumulative hypothesis so it cannot flood terminal scrollback", () => {
    const writes: string[] = [];
    const preview = new TerminalPreview((text) => writes.push(text), true, 12);
    preview.update("one two three four");
    expect(writes.at(-1)).toBe("… three four");
  });

  test("commits an identical active hypothesis without printing it twice", () => {
    const writes: string[] = [];
    const preview = new TerminalPreview((text) => writes.push(text), true);
    preview.update("Same transcript");
    preview.commit("Same transcript");
    expect(writes).toEqual(["Same transcript", "\n"]);
  });

  test("moves up across wrapped rows before replacing a preview", () => {
    const writes: string[] = [];
    const preview = new TerminalPreview((text) => writes.push(text), true, 40, 10);
    preview.update("1234567890abcdefghij");
    preview.update("replacement");
    expect(writes).toEqual([
      "1234567890abcdefghij",
      "\r",
      "\x1b[1A",
      "\x1b[J",
      "replacement",
    ]);
  });
});
