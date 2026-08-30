export class SlidingWindowRateLimiter {
  #acceptedAt: number[] = [];

  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
  ) {}

  accept(now = Date.now()): boolean {
    const oldestAllowed = now - this.windowMs;
    while (this.#acceptedAt[0] !== undefined && this.#acceptedAt[0] <= oldestAllowed) {
      this.#acceptedAt.shift();
    }
    if (this.#acceptedAt.length >= this.limit) return false;
    this.#acceptedAt.push(now);
    return true;
  }
}
