import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const TOKEN_PATTERN = /^[a-f0-9]{64}$/;
const PROTOCOL_PREFIX = "gemini-whisper-v1.";

export function localAuthTokenPath(): string {
  return (
    Bun.env.GEMINI_WHISPER_AUTH_TOKEN_FILE ??
    join(homedir(), ".config", "gemini-whisper-local", "auth-token")
  );
}

export async function ensureLocalAuthToken(): Promise<string> {
  const fromEnvironment = Bun.env.GEMINI_WHISPER_AUTH_TOKEN?.trim();
  if (fromEnvironment) return validateToken(fromEnvironment);

  const path = localAuthTokenPath();
  try {
    const existing = (await readFile(path, "utf8")).trim();
    await chmod(path, 0o600);
    return validateToken(existing);
  } catch (error) {
    if (!isMissingFile(error)) throw error;
  }

  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const token = crypto.getRandomValues(new Uint8Array(32)).toHex();
  try {
    await writeFile(path, `${token}\n`, { encoding: "utf8", mode: 0o600, flag: "wx" });
  } catch (error) {
    if (!isExistingFile(error)) throw error;
    return validateToken((await readFile(path, "utf8")).trim());
  }
  await chmod(path, 0o600);
  return token;
}

export function websocketAuthProtocol(token: string): string {
  return `${PROTOCOL_PREFIX}${validateToken(token)}`;
}

export function bearerAuthorization(token: string): string {
  return `Bearer ${validateToken(token)}`;
}

export function requestHasBearerToken(request: Request, token: string): boolean {
  return request.headers.get("authorization") === bearerAuthorization(token);
}

export function requestHasWebSocketToken(request: Request, token: string): boolean {
  const protocols = request.headers
    .get("sec-websocket-protocol")
    ?.split(",")
    .map((value) => value.trim());
  return protocols?.includes(websocketAuthProtocol(token)) === true;
}

function validateToken(token: string): string {
  if (!TOKEN_PATTERN.test(token)) {
    throw new Error("The Gemini Whisper local authentication token is invalid.");
  }
  return token;
}

function isMissingFile(error: unknown): boolean {
  return error instanceof Error && "code" in error && error.code === "ENOENT";
}

function isExistingFile(error: unknown): boolean {
  return error instanceof Error && "code" in error && error.code === "EEXIST";
}
