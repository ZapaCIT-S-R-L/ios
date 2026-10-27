#!/usr/bin/env bash
# Scans the pinned dependencies for known vulnerabilities with OSV-Scanner (CI on every PR and daily, and
# scripts/ci-local.sh):
#   ZapaKidKit/ and ZapaCalls/Package.resolved   our Swift packages: fails on ANY known vulnerability
#   package-lock.json             the Node test tools (contract test): fails on ANY known vulnerability
#   libsignal's Cargo.lock        the Rust crates inside Signal's prebuilt libsignal_ffi.a, at the tag in Podfile.lock
#                                 (OSV can't read Podfile.lock): fails on HIGH or CRITICAL (CVSS >= 7); others,
#                                 like "unmaintained" notices, are listed. We can't patch them: bump libsignal.
# A finding that can't be fixed yet is ignored only in osv-scanner.toml, with a reason and an expiry date, in a PR.
set -euo pipefail
cd "$(dirname "$0")/.."
image=ghcr.io/google/osv-scanner:v2.7.0@sha256:4f3b7e2c64b9d38a5febc5a7e4a3dfef1d1362f726dea7a2ef4762b46469fcd0
config=()
[ -f osv-scanner.toml ] && config=(--config "$PWD/osv-scanner.toml")

# OSV JSON for one lockfile (absolute path), from a local osv-scanner (brew) or else the pinned image (CI).
osv_json() {
  local dir file
  dir=$(dirname "$1")
  file=$(basename "$1")
  if command -v osv-scanner >/dev/null; then
    osv-scanner scan source "${config[@]}" --format json --lockfile "$1" 2>/dev/null || true
  else
    local mount=()
    [ -f osv-scanner.toml ] && mount=(-v "$PWD/osv-scanner.toml:/config/osv-scanner.toml:ro") \
      && config=(--config /config/osv-scanner.toml)
    docker run --rm -v "$dir:/scan:ro" "${mount[@]}" "$image" \
      scan source "${config[@]}" --format json --lockfile "/scan/$file" 2>/dev/null || true
  fi
}

# Prints the findings; exits 1 when one is at or above the threshold (0 = any finding).
judge() {
  python3 -I scripts/osv-judge.py "$1"
}

status=0
for package in ZapaKidKit ZapaCalls; do
  if [ -f "$package/Package.resolved" ]; then
    echo "== $package/Package.resolved (any finding fails)"
    osv_json "$PWD/$package/Package.resolved" | judge 0 || status=1
  else
    echo "== $package has no package dependencies yet"
  fi
done

if [ -f package-lock.json ]; then
  echo "== package-lock.json (any finding fails)"
  osv_json "$PWD/package-lock.json" | judge 0 || status=1
fi

tag=$(sed -nE 's/^ *:tag: (v[0-9]+\.[0-9]+\.[0-9]+)$/\1/p' Podfile.lock | sed -n 1p)
if [ -n "$tag" ]; then
  echo "== libsignal $tag Cargo.lock (HIGH/CRITICAL fail)"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/Cargo.lock" "https://raw.githubusercontent.com/signalapp/libsignal/$tag/Cargo.lock"
  osv_json "$tmp/Cargo.lock" | judge 7 || status=1
fi
exit $status
