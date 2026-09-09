#!/usr/bin/env python3
"""E1: how much formatting does gemini-3.5-transcribe-live already do itself?

Streams the same 16 kHz mono PCM16 audio to the Live API twice --
inputAudioTranscription.mode=SMART and mode=VERBATIM -- and prints the raw
final transcripts. If SMART output is already close to what Flash-Lite
produces, the second hop is redundant for most utterances.

Usage:
  scripts/exp-live-modes.py                 # synthesizes speech with `say`
  scripts/exp-live-modes.py rec1.wav ...    # uses real recordings

Reads GEMINI_API_KEY from .env. Never prints it.
"""

import asyncio
import base64
import json
import pathlib
import subprocess
import sys
import tempfile
import time
import wave

import websockets

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODEL = "gemini-3.5-transcribe-live"
URL = (
    "wss://generativelanguage.googleapis.com/ws/"
    "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
)
FRAME_BYTES = 1280  # 40 ms at 16 kHz mono PCM16, matching the app's chunker

SENTENCES = [
    "um so at src slash auth dot ts fix the two failing tests and for example preserve the exact error",
    "okay so here are the three things i want to do number one go to market "
    "number two buy some eggs number three go to sleep by twelve pm",
    "i think we should um probably just cache the the result and then move on actually scratch that lets not cache it",
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


KEY = api_key()


def synthesize(text: str, destination: pathlib.Path) -> pathlib.Path:
    raw = destination.with_suffix(".aiff")
    subprocess.run(["say", "-r", "170", "-o", str(raw), text], check=True)
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(raw), str(destination)],
        check=True,
    )
    return destination


def pcm_frames(path: pathlib.Path):
    with wave.open(str(path), "rb") as handle:
        if (handle.getnchannels(), handle.getsampwidth(), handle.getframerate()) != (1, 2, 16000):
            sys.exit(f"{path}: need 16 kHz mono PCM16")
        data = handle.readframes(handle.getnframes())
    for offset in range(0, len(data), FRAME_BYTES):
        yield data[offset : offset + FRAME_BYTES]


async def transcribe(path: pathlib.Path, mode: str):
    setup = {
        "setup": {
            "model": f"models/{MODEL}",
            "generationConfig": {"responseModalities": ["TEXT"]},
            "inputAudioTranscription": {
                "languageCodes": ["en-US"],
                "customVocabulary": [],
                "mode": mode,
            },
            "realtimeInputConfig": {"automaticActivityDetection": {"disabled": True}},
        }
    }
    interims, finals = [], []
    async with websockets.connect(f"{URL}?key={KEY}", max_size=None) as socket:
        await socket.send(json.dumps(setup))
        await socket.recv()  # setupComplete
        await socket.send(json.dumps({"realtimeInput": {"activityStart": {}}}))
        for frame in pcm_frames(path):
            await socket.send(
                json.dumps(
                    {
                        "realtimeInput": {
                            "audio": {
                                "data": base64.b64encode(frame).decode(),
                                "mimeType": "audio/pcm;rate=16000",
                            }
                        }
                    }
                )
            )
            await asyncio.sleep(0.04)  # stream at real time, as the app does
        stopped = time.monotonic()
        await socket.send(json.dumps({"realtimeInput": {"activityEnd": {}}}))
        await socket.send(json.dumps({"realtimeInput": {"audioStreamEnd": True}}))
        final_latency = None
        while True:
            try:
                message = json.loads(await asyncio.wait_for(socket.recv(), timeout=10))
            except asyncio.TimeoutError:
                break
            content = message.get("serverContent", {})
            if text := content.get("interimInputTranscription", {}).get("text"):
                interims.append(text)
            if text := content.get("inputTranscription", {}).get("text"):
                finals.append(text)
                if final_latency is None:
                    final_latency = (time.monotonic() - stopped) * 1000
            if content.get("turnComplete"):
                break
    return "".join(finals), interims, final_latency


async def main():
    paths = [pathlib.Path(arg) for arg in sys.argv[1:]]
    with tempfile.TemporaryDirectory() as workdir:
        if not paths:
            paths = [
                synthesize(text, pathlib.Path(workdir) / f"s{index}.wav")
                for index, text in enumerate(SENTENCES)
            ]
        for path in paths:
            print(f"\n{'=' * 78}\n{path.name}")
            for mode in ("VERBATIM", "SMART"):
                for attempt in range(3):
                    try:
                        text, interims, latency = await transcribe(path, mode)
                        break
                    except Exception as error:
                        if attempt == 2:
                            print(f"\n  [{mode}] FAILED: {type(error).__name__}: {error}")
                            text = interims = latency = None
                            break
                        await asyncio.sleep(5)
                if text is None:
                    continue
                stamp = f"{latency:.0f} ms" if latency else "no final"
                print(f"\n  [{mode}] final after activityEnd: {stamp}, {len(interims)} interims")
                print(f"    {text!r}")
                await asyncio.sleep(4)


asyncio.run(main())
