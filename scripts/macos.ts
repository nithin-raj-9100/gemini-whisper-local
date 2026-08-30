#!/usr/bin/env bun
import { chmod, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import {
  bearerAuthorization,
  ensureLocalAuthToken,
  localAuthTokenPath,
} from "../src/local-auth.ts";

const command = Bun.argv[2] ?? "help";
const projectRoot = new URL("..", import.meta.url).pathname.replace(/\/$/, "");
const userHome = homedir();
const label = "com.nithin.gemini-whisper";
const domain = `gui/${process.getuid?.() ?? 501}`;
const launchAgentsDirectory = join(userHome, "Library", "LaunchAgents");
const launchAgentPath = join(launchAgentsDirectory, `${label}.plist`);
const helperApp = join(projectRoot, "macos", "GeminiWhisperAudio.app");
const karabinerConfigPath = join(userHome, ".config", "karabiner", "karabiner.json");
const karabinerAssetPath = join(
  userHome,
  ".config",
  "karabiner",
  "assets",
  "complex_modifications",
  "gemini-whisper.json",
);
const ruleDescription = "Right Option toggles Gemini Whisper system dictation";

switch (command) {
  case "install":
    await install();
    break;
  case "uninstall":
    await uninstall();
    break;
  case "doctor":
    await doctor();
    break;
  default:
    console.log("Usage: bun run scripts/macos.ts <install|uninstall|doctor>");
}

async function install(): Promise<void> {
  requireMacOS();
  const dryRun = Bun.argv.includes("--dry-run");
  const required = ["swiftc", "codesign", "osascript", "launchctl"];
  const missing = required.filter((name) => !Bun.which(name));
  if (missing.length > 0) {
    throw new Error(
      `Missing stock macOS developer tools: ${missing.join(", ")}. Run xcode-select --install, ` +
        "finish the Apple installer, then rerun this command.",
    );
  }

  if (dryRun) {
    console.log(`Would build the microphone helper in ${helperApp}`);
    console.log(`Would install ${launchAgentPath}`);
    console.log(`Would configure Karabiner at ${karabinerConfigPath}`);
    console.log(`ffmpeg: ${Bun.which("ffmpeg") ? "available" : "not installed (optional)"}`);
    return;
  }

  await ensureLocalAuthToken();
  await run([process.execPath, "run", "system:audio:build"], "build the microphone helper");
  await mkdir(launchAgentsDirectory, { recursive: true, mode: 0o700 });
  await writeFile(launchAgentPath, launchAgentPlist(), { encoding: "utf8", mode: 0o600 });
  await chmod(launchAgentPath, 0o600);
  await installKarabinerRule();

  await runIgnoringFailure(["/bin/launchctl", "bootout", domain, launchAgentPath]);
  await run(["/bin/launchctl", "bootstrap", domain, launchAgentPath], "install the LaunchAgent");
  await run(
    ["/bin/launchctl", "kickstart", "-k", `${domain}/${label}`],
    "start the background service",
  );

  await runIgnoringFailure([
    "/usr/bin/open",
    "-n",
    "-g",
    helperApp,
    "--args",
    "--permission-only",
  ]);

  console.log("Installed Gemini Whisper system dictation.");
  console.log("macOS may now request Microphone permission for Gemini Whisper Audio.");
  console.log("Enable Accessibility for Bun when macOS requests permission to paste text.");
  if (!(await karabinerInstalled())) {
    console.log(
      `Karabiner-Elements is not installed. The rule was prepared at ${karabinerAssetPath}; ` +
        "install Karabiner-Elements, then enable the Gemini Whisper complex modification.",
    );
  }
  if (!Bun.which("ffmpeg")) {
    console.log("ffmpeg is optional and is only needed for standalone mic/file/device commands.");
  }
  console.log("Run: bun run doctor:macos");
}

async function uninstall(): Promise<void> {
  requireMacOS();
  await runIgnoringFailure(["/bin/launchctl", "bootout", domain, launchAgentPath]);
  await removeKarabinerRule();
  await rm(launchAgentPath, { force: true });
  await rm(helperApp, { recursive: true, force: true });
  if (Bun.argv.includes("--purge")) {
    await rm(dirname(localAuthTokenPath()), { recursive: true, force: true });
  }
  console.log("Uninstalled Gemini Whisper. macOS privacy entries may be removed manually.");
}

async function doctor(): Promise<void> {
  requireMacOS();
  const checks: Array<{ name: string; ok: boolean; required: boolean; detail: string }> = [];
  const commandCheck = (name: string, required = true) => {
    const path = Bun.which(name);
    checks.push({ name, ok: Boolean(path), required, detail: path ?? "not found" });
  };
  commandCheck("bun");
  commandCheck("swiftc");
  commandCheck("codesign");
  commandCheck("osascript");
  commandCheck("pbcopy", false);
  commandCheck("pbpaste", false);
  commandCheck("ffmpeg", false);

  checks.push({
    name: "Gemini API key",
    ok: Boolean(Bun.env.GEMINI_API_KEY),
    required: true,
    detail: Bun.env.GEMINI_API_KEY ? "configured" : "missing from the project .env",
  });
  checks.push({
    name: "Karabiner-Elements",
    ok: await karabinerInstalled(),
    required: true,
    detail: (await karabinerInstalled()) ? "installed" : "not installed",
  });
  checks.push({
    name: "microphone helper",
    ok: await Bun.file(join(helperApp, "Contents", "MacOS", "GeminiWhisperAudio")).exists(),
    required: true,
    detail: helperApp,
  });
  checks.push({
    name: "LaunchAgent",
    ok: await Bun.file(launchAgentPath).exists(),
    required: true,
    detail: launchAgentPath,
  });

  try {
    const token = await ensureLocalAuthToken();
    const tokenMode = (await stat(localAuthTokenPath())).mode & 0o777;
    checks.push({
      name: "local authentication",
      ok: token.length === 64 && tokenMode === 0o600,
      required: true,
      detail: tokenMode === 0o600 ? "token protected with mode 0600" : `unsafe mode ${tokenMode.toString(8)}`,
    });
    const health = await fetch("http://127.0.0.1:8766/health").catch(() => undefined);
    checks.push({
      name: "background service",
      ok: health?.ok === true,
      required: true,
      detail: health ? `HTTP ${health.status}` : "not reachable",
    });
    const permission = await fetch("http://127.0.0.1:8766/permissions", {
      headers: { Authorization: bearerAuthorization(token) },
    }).catch(() => undefined);
    const permissionBody = permission?.ok
      ? ((await permission.json()) as { pasteAutomation?: boolean })
      : undefined;
    checks.push({
      name: "Accessibility paste permission",
      ok: permissionBody?.pasteAutomation === true,
      required: true,
      detail: permissionBody?.pasteAutomation ? "enabled" : "not enabled",
    });
  } catch (error) {
    checks.push({
      name: "local authentication",
      ok: false,
      required: true,
      detail: error instanceof Error ? error.message : "token check failed",
    });
  }

  for (const check of checks) {
    console.log(`${check.ok ? "PASS" : check.required ? "FAIL" : "INFO"}  ${check.name}: ${check.detail}`);
  }
  if (checks.some((check) => check.required && !check.ok)) process.exitCode = 1;
}

async function installKarabinerRule(): Promise<void> {
  const rule = karabinerRule();
  await mkdir(dirname(karabinerAssetPath), { recursive: true, mode: 0o700 });
  await writeFile(
    karabinerAssetPath,
    `${JSON.stringify({ title: "Gemini Whisper", rules: [rule] }, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  if (!(await Bun.file(karabinerConfigPath).exists())) return;

  const config = JSON.parse(await readFile(karabinerConfigPath, "utf8")) as KarabinerConfig;
  const profile = config.profiles?.find((candidate) => candidate.selected) ?? config.profiles?.[0];
  if (!profile) return;
  profile.complex_modifications ??= { rules: [] };
  profile.complex_modifications.rules = profile.complex_modifications.rules.filter(
    (candidate) => !isGeminiWhisperRule(candidate),
  );
  profile.complex_modifications.rules.unshift(rule);
  await writeFile(karabinerConfigPath, `${JSON.stringify(config, null, 4)}\n`, "utf8");
}

async function removeKarabinerRule(): Promise<void> {
  await rm(karabinerAssetPath, { force: true });
  if (!(await Bun.file(karabinerConfigPath).exists())) return;
  const config = JSON.parse(await readFile(karabinerConfigPath, "utf8")) as KarabinerConfig;
  for (const profile of config.profiles ?? []) {
    if (profile.complex_modifications) {
      profile.complex_modifications.rules = profile.complex_modifications.rules.filter(
        (candidate) => !isGeminiWhisperRule(candidate),
      );
    }
  }
  await writeFile(karabinerConfigPath, `${JSON.stringify(config, null, 4)}\n`, "utf8");
}

function karabinerRule(): KarabinerRule {
  return {
    description: ruleDescription,
    manipulators: [
      {
        type: "basic",
        from: { key_code: "right_option", modifiers: { optional: ["any"] } },
        parameters: { "basic.to_if_alone_timeout_milliseconds": 500 },
        to: [{ key_code: "right_option", lazy: true }],
        to_if_alone: [
          {
            shell_command: `${shellQuote(process.execPath)} run ${shellQuote(join(projectRoot, "src", "system-trigger.ts"))}`,
          },
        ],
      },
    ],
  };
}

function isGeminiWhisperRule(rule: KarabinerRule): boolean {
  const description = rule.description.toLocaleLowerCase();
  if (description.includes("right option toggles gemini-whisper system dictation")) return true;
  if (description.includes("right option toggles gemini whisper system dictation")) return true;
  return JSON.stringify(rule.manipulators).includes("gemini-whisper/src/system-trigger.ts");
}

function launchAgentPlist(): string {
  const path = [dirname(process.execPath), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    .join(":");
  const logDirectory = join(userHome, "Library", "Logs");
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${xml(label)}</string>
<key>ProgramArguments</key><array><string>${xml(process.execPath)}</string><string>run</string><string>src/system-service.ts</string></array>
<key>WorkingDirectory</key><string>${xml(projectRoot)}</string>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>${xml(path)}</string></dict>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>3</integer>
<key>StandardOutPath</key><string>${xml(join(logDirectory, "gemini-whisper.log"))}</string>
<key>StandardErrorPath</key><string>${xml(join(logDirectory, "gemini-whisper.error.log"))}</string>
</dict></plist>\n`;
}

async function karabinerInstalled(): Promise<boolean> {
  for (const path of [
    "/Applications/Karabiner-Elements.app",
    join(userHome, "Applications", "Karabiner-Elements.app"),
  ]) {
    try {
      if ((await stat(path)).isDirectory()) return true;
    } catch (error) {
      if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) throw error;
    }
  }
  return false;
}

async function run(command: string[], purpose: string): Promise<void> {
  const process = Bun.spawn(command, { cwd: projectRoot, stdin: "ignore", stdout: "inherit", stderr: "pipe" });
  const detail = new Response(process.stderr).text();
  const exitCode = await process.exited;
  if (exitCode !== 0) throw new Error(`Could not ${purpose}: ${(await detail).trim() || `exit ${exitCode}`}`);
}

async function runIgnoringFailure(command: string[]): Promise<void> {
  const process = Bun.spawn(command, { stdin: "ignore", stdout: "ignore", stderr: "ignore" });
  await process.exited;
}

function requireMacOS(): void {
  if (process.platform !== "darwin") throw new Error("This command currently supports macOS only.");
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

function xml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

interface KarabinerRule {
  description: string;
  manipulators: Array<Record<string, unknown>>;
}

interface KarabinerConfig {
  profiles?: Array<{
    selected?: boolean;
    complex_modifications?: { rules: KarabinerRule[] };
  }>;
}
