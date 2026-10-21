#!/usr/bin/env python3
"""Summarize paste timings and dictation reliability without printing dictated text or credentials."""
import argparse
import collections
import json
from pathlib import Path
import re
import statistics


def summarize(path, since=None, last=6):
    rows = []
    for line in path.read_text(errors="replace").splitlines():
        stamp = line[:20]
        if since and stamp < since:
            continue
        match = re.search(r"Inserted (\d+) characters in (\d+) ms after stop", line)
        if match:
            rows.append({"utc": stamp, "total_ms": int(match[2])})
        elif "latency session=" in line and rows:
            fields = dict(re.findall(r"([a-z_]+)=([^ ]+)", line))
            if fields.get("pasted") != "true":
                continue
            if rows[-1]["total_ms"] != int(fields.get("total_ms", -1)):
                continue
            for key in ("capture_ms", "live_ms", "polish_wait_ms", "delivery_ms", "background_jobs", "final_jobs"):
                if key in fields:
                    rows[-1][key] = int(fields[key])
            rows[-1]["outcome"] = fields.get("outcome", "unknown")
            rows[-1]["live_fallback"] = fields.get("live_fallback") == "true"
    rows = rows[-last:] if last else rows
    if not rows:
        return {"count": 0}
    values = [r["total_ms"] for r in rows]
    result = {"count": len(rows), "mean_ms": round(statistics.mean(values), 1),
              "median_ms": statistics.median(values), "min_ms": min(values), "max_ms": max(values),
              "outcomes": dict(collections.Counter(r.get("outcome", "legacy_unknown") for r in rows)),
              "measure": "Stop handler to Cmd+V posting; not confirmed destination rendering",
              "rows": rows}
    for key in ("capture_ms", "live_ms", "polish_wait_ms", "delivery_ms", "background_jobs", "final_jobs"):
        stage = [r[key] for r in rows if key in r]
        if stage:
            result[key] = {"count": len(stage), "mean": round(statistics.mean(stage), 1)}
    return result


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def reliability(path, since=None):
    """Per-dictation outcomes from `outcome ...` log lines.

    attempts excludes dictations the user abandoned (Escape, sleep). delivered
    counts insertions the app did not later flag as unconfirmed. recovered means
    the text ended on the clipboard instead; failed dictations keep their audio
    for "Retry Last Dictation".
    """
    results = collections.Counter()
    problems = collections.Counter()
    batch = collections.Counter()
    sources = collections.Counter()
    stop_to_paste = []
    for line in path.read_text(errors="replace").splitlines():
        stamp = line[:20]
        if since and stamp < since:
            continue
        if " outcome_update " in line:
            fields = dict(re.findall(r"([a-z_]+)=([^ ]+)", line.split(" outcome_update ", 1)[1]))
            if fields.get("result") == "paste_unconfirmed":
                results["paste_unconfirmed"] += 1
            continue
        if " outcome session=" not in line:
            continue
        fields = dict(re.findall(r"([a-z_]+)=([^ ]+)", line.split(" outcome ", 1)[1]))
        result = fields.get("result", "unknown")
        results[result] += 1
        sources[fields.get("source", "none")] += 1
        if result != "inserted":
            problems[f"{result}:{fields.get('code', 'none')}"] += 1
        if fields.get("batch", "none") != "none":
            batch[fields["batch"]] += 1
        if "stop_to_paste_ms" in fields:
            stop_to_paste.append(int(fields["stop_to_paste_ms"]))
    attempts = sum(results.values()) - results["cancelled"] - results["interrupted"] - results["paste_unconfirmed"]
    delivered = results["inserted"] - results["paste_unconfirmed"]
    recovered = results["copied"] + results["paste_unconfirmed"]
    report = {
        "attempts": attempts,
        "delivered": delivered,
        "recovered_to_clipboard": recovered,
        "failed_audio_kept": results["failed"],
        "empty": results["empty"],
        "abandoned": results["cancelled"] + results["interrupted"],
        "delivered_rate": round(delivered / attempts, 4) if attempts else None,
        "results": dict(results),
        "problems": dict(problems),
        "transcript_sources": dict(sources),
        "batch_recoveries": dict(batch),
    }
    if stop_to_paste:
        report["stop_to_paste_ms"] = {
            "p50": percentile(stop_to_paste, 0.5),
            "p95": percentile(stop_to_paste, 0.95),
            "max": max(stop_to_paste),
        }
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, default=Path.home() / "Library/Logs/gemini-whisper.app.log")
    parser.add_argument("--since", help="UTC timestamp, e.g. 2026-09-06T17:08:21Z")
    parser.add_argument("--last", type=int, default=6, help="Last N insertions; 0 includes all")
    args = parser.parse_args()
    if args.last < 0:
        parser.error("--last must be nonnegative")
    summary = summarize(args.log, args.since, args.last)
    summary["reliability"] = reliability(args.log, args.since)
    print(json.dumps(summary, indent=2))
