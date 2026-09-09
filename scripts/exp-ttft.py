#!/usr/bin/env python3
"""E2: does thinkingBudget:0 actually suppress thinking on gemini-3.5-flash-lite?

Measures TTFT (first SSE chunk carrying text) across thinking configs, and reads
usageMetadata.thoughtsTokenCount from a non-streaming call per config -- that
field is the ground truth for whether the config was honored.

Reads GEMINI_API_KEY from .env. Never prints it.
"""

import json
import os
import pathlib
import random
import re
import statistics
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODEL = os.environ.get("GEMINI_WHISPER_INTELLIGENCE_MODEL", "gemini-3.5-flash-lite")
TRIALS = int(os.environ.get("TRIALS", "6"))
PACE_S = float(os.environ.get("PACE_S", "1.5"))

CONFIGS = {
    "level_minimal": {"thinkingLevel": "minimal"},
    "level_low": {"thinkingLevel": "low"},
    "omitted": None,
}

PROMPTS = [
    "um so at src slash auth dot ts fix the two failing tests and for example preserve the exact error",
    "okay so i think we should um probably just cache the the result and then move on",
    "let's see if this actually works now here are the three things i want to do number one go to market number two buy some eggs number three go to sleep by 12 pm",
]


def api_key() -> str:
    for path in (ROOT / ".env", ROOT / "macos/GeminiWhisper.app/Contents/Resources/.env"):
        if not path.exists():
            continue
        for line in path.read_text().splitlines():
            if line.startswith("GEMINI_API_KEY="):
                value = line.split("=", 1)[1].strip().strip('"').strip("'")
                if value:
                    return value
    sys.exit("GEMINI_API_KEY not found in .env")


def system_instruction() -> str:
    src = (ROOT / "macos/GeminiWhisper/Sources/GeminiWhisperCore/Intelligence.swift").read_text()
    match = re.search(r'TRANSCRIPT_INTELLIGENCE_SYSTEM_INSTRUCTION = """\n(.*?)\n"""', src, re.S)
    if not match:
        sys.exit("could not extract system instruction")
    return match.group(1)


INSTRUCTION = system_instruction()
KEY = api_key()


def body(prompt: str, thinking) -> bytes:
    generation_config = {"maxOutputTokens": 400}
    if thinking is not None:
        generation_config["thinkingConfig"] = thinking
    return json.dumps(
        {
            "systemInstruction": {"parts": [{"text": INSTRUCTION}]},
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": generation_config,
        }
    ).encode()


def call(endpoint: str, payload: bytes):
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:{endpoint}"
    request = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json", "x-goog-api-key": KEY},
    )
    return urllib.request.urlopen(request, timeout=60)


def ttft(prompt: str, thinking):
    payload = body(prompt, thinking)
    started = time.monotonic()
    try:
        response = call("streamGenerateContent?alt=sse", payload)
    except urllib.error.HTTPError as error:
        return None, None, f"HTTP {error.code}: {error.read()[:200].decode(errors='replace')}"
    except OSError as error:
        return None, None, f"connect reset: {error}"
    first = None
    try:
        for raw in response:
            line = raw.decode(errors="replace").strip()
            if not line.startswith("data:"):
                continue
            chunk = json.loads(line[5:])
            text = "".join(
                part.get("text", "")
                for candidate in chunk.get("candidates", [])
                for part in candidate.get("content", {}).get("parts", [])
                if not part.get("thought")
            )
            if text and first is None:
                first = time.monotonic() - started
    except OSError as error:
        if first is None:
            return None, None, f"stream reset: {error}"
    return first, time.monotonic() - started, None


def thought_tokens(prompt: str, thinking):
    try:
        response = call("generateContent", body(prompt, thinking))
    except urllib.error.HTTPError as error:
        return f"HTTP {error.code}: {error.read()[:300].decode(errors='replace')}"
    usage = json.load(response).get("usageMetadata", {})
    return {k: usage.get(k) for k in ("promptTokenCount", "thoughtsTokenCount", "candidatesTokenCount")}


print(f"model={MODEL} trials={TRIALS} instruction_chars={len(INSTRUCTION)}\n")

# Configs are interleaved and shuffled: running each config as a contiguous
# block lets free-tier throttling accumulate onto whichever block runs last,
# which swamps the effect being measured.
schedule = [
    (name, PROMPTS[index % len(PROMPTS)])
    for index in range(TRIALS)
    for name in CONFIGS
]
random.shuffle(schedule)

samples = {name: [] for name in CONFIGS}
errors = {name: [] for name in CONFIGS}

for position, (name, prompt) in enumerate(schedule, 1):
    first, _, error = ttft(prompt, CONFIGS[name])
    if error:
        errors[name].append(error)
    elif first is not None:
        samples[name].append(first * 1000)
    print(f"\r  {position}/{len(schedule)}", end="", flush=True)
    time.sleep(PACE_S)
print("\r" + " " * 24)

for name, thinking in CONFIGS.items():
    print(f"--- {name}: {json.dumps(thinking)}")
    values = sorted(samples[name])
    if values:
        index90 = min(len(values) - 1, int(len(values) * 0.9))
        print(
            f"    ttft_ms n={len(values)} min={values[0]:.0f} "
            f"median={statistics.median(values):.0f} "
            f"p90={values[index90]:.0f} max={values[-1]:.0f}"
        )
    if errors[name]:
        print(f"    errors={len(errors[name])}: {errors[name][0][:120]}")

print(f"\nusageMetadata: {thought_tokens(PROMPTS[0], CONFIGS['level_minimal'])}")
