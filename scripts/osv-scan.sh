#!/usr/bin/env bash
# Scans the pinned Swift packages (ZapaKidKit/Package.resolved) for known vulnerabilities with OSV-Scanner.
# Fails on any known vulnerability (stricter than high/critical only). A finding that can't be fixed yet is
# ignored only in osv-scanner.toml, with a reason and an expiry date, in a reviewed PR.
set -euo pipefail
cd "$(dirname "$0")/.."
lockfile=ZapaKidKit/Package.resolved
if [ ! -f "$lockfile" ]; then
  echo "No $lockfile: ZapaKidKit has no package dependencies yet, nothing to scan."
  exit 0
fi
config=()
[ -f osv-scanner.toml ] && config=(--config /repo/osv-scanner.toml)
docker run --rm -v "$PWD:/repo:ro" \
  ghcr.io/google/osv-scanner:v2.7.0@sha256:4f3b7e2c64b9d38a5febc5a7e4a3dfef1d1362f726dea7a2ef4762b46469fcd0 \
  scan source "${config[@]}" --lockfile "/repo/$lockfile"
