export type TerminalWriter = (text: string) => void;

/**
 * Renders one replaceable, potentially multi-line terminal region.
 *
 * Tracks the physical rows occupied by the preview, then moves back to its
 * origin before redrawing. This avoids relying on terminal cursor-save state,
 * which can be lost when wrapped output scrolls.
 */
export class TerminalPreview {
  #active = false;
  #activeText = "";
  #renderedRows = 0;

  constructor(
    private readonly write: TerminalWriter,
    private readonly interactive: boolean,
    private readonly maximumCharacters = 240,
    private readonly columns = 80,
  ) {}

  update(text: string): void {
    const visibleText = truncateFromStart(text, this.maximumCharacters);
    if (!this.interactive) {
      this.write(`\r\x1b[2K${visibleText}`);
      return;
    }

    if (this.#active) this.#eraseActiveRegion();
    this.#active = true;
    this.#activeText = visibleText;
    this.#renderedRows = countRenderedRows(visibleText, this.columns);
    this.write(visibleText);
  }

  commit(text: string): void {
    if (this.interactive && this.#active && text === this.#activeText) {
      this.write("\n");
      this.#active = false;
      this.#activeText = "";
      this.#renderedRows = 0;
      return;
    }
    this.clear();
    this.write(`${text}\n`);
  }

  clear(): void {
    if (!this.#active) return;
    this.#eraseActiveRegion();
    this.#active = false;
    this.#activeText = "";
    this.#renderedRows = 0;
  }

  #eraseActiveRegion(): void {
    this.write("\r");
    if (this.#renderedRows > 1) this.write(`\x1b[${this.#renderedRows - 1}A`);
    this.write("\x1b[J");
  }
}

function truncateFromStart(text: string, maximumCharacters: number): string {
  if (text.length <= maximumCharacters) return text;
  return `…${text.slice(-(maximumCharacters - 1))}`;
}

function countRenderedRows(text: string, columns: number): number {
  const safeColumns = Math.max(1, columns);
  return text.split("\n").reduce((rows, line) => {
    const characterCount = [...line].length;
    return rows + Math.max(1, Math.ceil(characterCount / safeColumns));
  }, 0);
}
