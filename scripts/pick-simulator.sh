#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator on the newest installed iOS runtime.
# Set SIM_UDID to use a specific simulator instead (for example one you created for this repo), or SIM_DEVICE
# (and optionally SIM_OS, like 26.5) to pick one by name, as CI does.
set -euo pipefail
if [ -n "${SIM_UDID:-}" ]; then echo "$SIM_UDID"; exit 0; fi
xcrun simctl list devices available -j | SIM_DEVICE="${SIM_DEVICE:-}" SIM_OS="${SIM_OS:-}" python3 -c '
import json, os, re, sys
devices = json.load(sys.stdin)["devices"]
name, os_version = os.environ["SIM_DEVICE"], os.environ["SIM_OS"]
def version(runtime):
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(m.group(1)), int(m.group(2))) if m else (-1, -1)
for runtime in sorted((r for r in devices if "iOS" in r), key=version, reverse=True):
    if os_version and "iOS-" + os_version.replace(".", "-") not in runtime:
        continue
    phones = [d for d in devices[runtime] if (d["name"] == name if name else d["name"].startswith("iPhone"))]
    if phones:
        print(phones[0]["udid"])
        sys.exit(0)
sys.exit(f"No simulator found (SIM_DEVICE={name!r}, SIM_OS={os_version!r})")
'
