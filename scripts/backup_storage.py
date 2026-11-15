#!/usr/bin/env python3
"""Mirror a Supabase Storage bucket to a local folder (incremental). Used by `just backup`.

usage: backup_storage.py <project-ref> <bucket> <dest-dir>
env:   ZONE2_SERVICE_KEY (the project's service-role key; `just backup` reads it from the supabase CLI)

Object keys are immutable (HealthKit dumps by workout uuid, FIT by sha256), so a file that exists
locally with the same size is skipped. Nothing is deleted locally. HTTPS goes through curl
(python.org builds often lack a CA bundle).
"""
import json
import os
import subprocess
import sys


def curl(args: list[str], data: bytes | None = None) -> bytes:
    out = subprocess.run(["curl", "-sS", "--fail-with-body", "--max-time", "300", *args],
                         input=data, capture_output=True)
    if out.returncode != 0:
        raise RuntimeError(f"curl {args[-1]}: {out.stderr.decode().strip()} {out.stdout[:200]!r}")
    return out.stdout


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    ref, bucket, dest = sys.argv[1:4]
    service = os.environ.get("ZONE2_SERVICE_KEY") or sys.exit("ZONE2_SERVICE_KEY is not set")
    base = f"https://{ref}.supabase.co/storage/v1"
    auth = ["-H", f"authorization: Bearer {service}", "-H", f"apikey: {service}"]

    def listdir(prefix: str) -> list[dict]:
        items, offset = [], 0
        while True:
            body = json.dumps({"prefix": prefix, "limit": 1000, "offset": offset,
                               "sortBy": {"column": "name", "order": "asc"}}).encode()
            page = json.loads(curl([*auth, "-H", "content-type: application/json", "-X", "POST",
                                    "--data-binary", "@-", f"{base}/object/list/{bucket}"], body))
            items += page
            if len(page) < 1000:
                return items
            offset += 1000

    copied = skipped = 0
    stack = [""]
    while stack:
        prefix = stack.pop()
        for it in listdir(prefix):
            key = f"{prefix}{it['name']}"
            if it.get("id") is None:  # a folder
                stack.append(key + "/")
                continue
            size = (it.get("metadata") or {}).get("size")
            path = os.path.join(dest, key)
            if os.path.exists(path) and (size is None or os.path.getsize(path) == size):
                skipped += 1
                continue
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = path + ".part"
            curl([*auth, "-o", tmp, f"{base}/object/{bucket}/{key}"])
            os.replace(tmp, path)
            copied += 1
    print(f"storage {bucket}: {copied} copied, {skipped} already there")


if __name__ == "__main__":
    main()
