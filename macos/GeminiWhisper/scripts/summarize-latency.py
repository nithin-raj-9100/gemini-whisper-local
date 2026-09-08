#!/usr/bin/env python3
"""Summarize successful paste timings without printing dictated text or credentials."""
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, default=Path.home() / "Library/Logs/gemini-whisper.app.log")
    parser.add_argument("--since", help="UTC timestamp, e.g. 2026-09-06T17:08:21Z")
    parser.add_argument("--last", type=int, default=6, help="Last N insertions; 0 includes all")
    args = parser.parse_args()
    if args.last < 0:
        parser.error("--last must be nonnegative")
    print(json.dumps(summarize(args.log, args.since, args.last), indent=2))
