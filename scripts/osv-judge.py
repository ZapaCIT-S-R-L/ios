"""Reads OSV-Scanner JSON on stdin, prints each finding, exits 1 if one is at or above the CVSS threshold.

Usage: osv-scanner ... --format json | python3 scripts/osv-judge.py THRESHOLD   (0 = every finding fails)
"""

import json
import sys


def main() -> int:
    threshold = float(sys.argv[1])
    data = json.loads(sys.stdin.read() or "{}")
    failed = False
    for result in data.get("results") or []:
        for pkg in result.get("packages") or []:
            name, version = pkg["package"]["name"], pkg["package"]["version"]
            for group in pkg.get("groups") or []:
                score = float(group.get("max_severity") or 0)
                blocking = threshold == 0 or score >= threshold
                failed = failed or blocking
                ids = ",".join(group["ids"])
                print(f"{'FAIL' if blocking else 'note'} {name} {version}: {ids} (CVSS {score or 'unknown'})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
