#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator on the newest installed iOS runtime.
# Set SIM_UDID to use a specific simulator instead (for example one you created for this repo).
set -euo pipefail
if [ -n "${SIM_UDID:-}" ]; then echo "$SIM_UDID"; exit 0; fi
xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(m.group(1)), int(m.group(2))) if m else (-1, -1)
for runtime in sorted((r for r in devices if "iOS" in r), key=version, reverse=True):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"])
        sys.exit(0)
sys.exit("No iPhone simulator found")
'
