#!/usr/bin/env python3
"""Write a Claude usage snapshot for manual UI checks.

Sample data always reports both windows, so states like "weekly only",
"expired" and "stale" cannot be reached through Show Sample Data. This writes a
snapshot the app will read when NOCCI_DATA_DIR points at the same
directory, leaving the real snapshot untouched.

Dates use Swift's default JSON encoding, which is seconds since 2001-01-01, not
the Unix epoch.

    python3 Tests/fixture.py /tmp/notch-fixture --weekly 62
    NOCCI_DATA_DIR=/tmp/notch-fixture open -n '../Nocci.app'

Quit the running instance first; two instances fight over the same notch.
"""

import argparse
import json
import os
import time

SWIFT_EPOCH = 978307200.0


def swift_time(unix_seconds):
    return unix_seconds - SWIFT_EPOCH


def window(label, kind, used, reset_seconds):
    entry = {"label": label, "kind": kind, "used": used}
    if reset_seconds is not None:
        entry["reset"] = swift_time(time.time() + reset_seconds)
    return entry


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directory", help="value to pass as NOCCI_DATA_DIR")
    parser.add_argument("--session", type=float, help="session window used percentage; omit to leave it out")
    parser.add_argument("--weekly", type=float, help="weekly window used percentage; omit to leave it out")
    parser.add_argument("--age", type=float, default=0.0,
                        help="minutes since the reading was captured; 5 or more renders as stale")
    parser.add_argument("--session-expired", action="store_true", help="put the session reset in the past")
    parser.add_argument("--weekly-expired", action="store_true", help="put the weekly reset in the past")
    parser.add_argument("--no-kind", action="store_true",
                        help="omit the kind field, as snapshots written by older builds do")
    args = parser.parse_args()

    windows = []
    if args.session is not None:
        windows.append(window("5-hour", "session", args.session,
                              -60 if args.session_expired else 2 * 3600))
    if args.weekly is not None:
        windows.append(window("Weekly", "weekly", args.weekly,
                              -60 if args.weekly_expired else 4 * 24 * 3600))
    if args.no_kind:
        for entry in windows:
            entry.pop("kind")

    captured = swift_time(time.time() - args.age * 60)
    snapshot = {"windows": windows, "updated": captured, "lastEvent": captured}

    os.makedirs(args.directory, mode=0o700, exist_ok=True)
    path = os.path.join(args.directory, "claude.json")
    with open(path, "w") as handle:
        json.dump(snapshot, handle)
    os.chmod(path, 0o600)

    described = ", ".join(f"{w['label']} {w['used']}%" for w in windows) or "no windows"
    print(f"wrote {path}: {described}, captured {args.age:g} minutes ago")


if __name__ == "__main__":
    main()
