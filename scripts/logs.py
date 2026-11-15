#!/usr/bin/env python3
"""Edge Function logs from the Supabase Management API (read-only). Used by `just logs`.

usage: logs.py <project-ref> <since: 30m|2h|1d> [grep] [src: fn|edge|all] [limit]
env:   ZONE2_SUPABASE_ACCESS_TOKEN

The unified `logs` table has a `source` column: function_logs = our JSON lines (backend/src/log.ts),
function_edge_logs = Supabase's own request log. The endpoint allows 10 requests/min per account.
HTTPS goes through curl: python.org builds often lack a CA bundle.
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

SOURCES = {
    "fn": ["function_logs"],
    "edge": ["function_edge_logs"],
    "all": ["function_logs", "function_edge_logs"],
}


def lit(s: str) -> str:
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


def iso(d: datetime) -> str:
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def fmt(ts: str, msg: str) -> str:
    try:
        d = json.loads(msg)
    except ValueError:
        d = None
    if not isinstance(d, dict):
        return f"{ts} {msg[:500]}"
    d.pop("ts", None)
    head = f"{d.pop('level', '-'):5} {d.pop('msg', '')}"
    if "requestId" in d:
        d["requestId"] = str(d["requestId"])[:8]
    kv = " ".join(
        f"{k}={json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v}"
        for k, v in d.items()
    )
    return f"{ts} {head} {kv}".rstrip()


def main() -> None:
    args = sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    ref, since = args[0], args[1]
    needle = args[2] if len(args) > 2 else ""
    src = args[3] if len(args) > 3 else "fn"
    limit = int(args[4]) if len(args) > 4 else 300
    token = os.environ.get("ZONE2_SUPABASE_ACCESS_TOKEN") or sys.exit("ZONE2_SUPABASE_ACCESS_TOKEN is not set")

    m = re.fullmatch(r"(\d+)([mhd])", since) or sys.exit(f"since: like 30m, 2h, 1d (got {since})")
    unit = {"m": "minutes", "h": "hours", "d": "days"}[m[2]]
    end = datetime.now(timezone.utc)
    start = end - timedelta(**{unit: int(m[1])})
    if src not in SOURCES:
        sys.exit("src: fn | edge | all")

    where = [f"source in ({', '.join(map(lit, SOURCES[src]))})"]
    if needle:
        where.append(f"event_message like {lit('%' + needle + '%')}")
    sql = (
        "select timestamp, event_message from logs where "
        + " and ".join(where)
        + f" order by timestamp desc limit {limit}"
    )

    out = subprocess.run(
        [
            "curl", "-sS", "--max-time", "60", "-G", "-w", "\n%{http_code}",
            f"https://api.supabase.com/v1/projects/{ref}/analytics/endpoints/logs",
            "-H", f"authorization: Bearer {token}",
            "--data-urlencode", f"sql={sql}",
            "--data-urlencode", f"iso_timestamp_start={iso(start)}",
            "--data-urlencode", f"iso_timestamp_end={iso(end)}",
        ],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit(f"curl: {out.stderr.strip()}")
    raw, _, status = out.stdout.rpartition("\n")
    if status != "200":
        hint = " (logs endpoint allows 10 requests/min; wait a minute)" if status == "429" or "Throttler" in raw else ""
        sys.exit(f"HTTP {status}: {raw[:300]}{hint}")
    body = json.loads(raw)
    if body.get("error"):
        sys.exit(f"error: {body['error']}")
    if "Throttler" in str(body.get("message", "")):
        sys.exit("rate limited: logs endpoint allows 10 requests/min; wait a minute")

    rows = list(reversed(body.get("result") or []))
    for row in rows:
        print(fmt(row["timestamp"][11:19], row["event_message"].strip()))
    more = " (limit reached: narrow the window or filter)" if len(rows) >= limit else ""
    print(f"— {len(rows)} lines, {iso(start)} … {iso(end)} UTC{more}", file=sys.stderr)


if __name__ == "__main__":
    main()
