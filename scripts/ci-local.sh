#!/usr/bin/env bash
# Runs the whole CI suite on this Mac. Push a PR branch only when this is green, and paste the summary it prints
# into the PR description.
#   scripts/ci-local.sh                       everything (XcodeGen, build, unit + UI tests, lint, Node, OSV, gitleaks)
#   SIM_UDID=<udid> scripts/ci-local.sh       on this simulator (else scripts/pick-simulator.sh chooses)
# Needs: brew install xcodegen swiftformat swiftlint actionlint gitleaks osv-scanner node
# Kind to a shared Mac: one xcodebuild with 2 jobs, one simulator, shut down at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

# The tool versions CI pins (by image tag), so a local pass means a CI pass.
want() { grep -oE "$1:[0-9.v]+" .github/workflows/ci.yml | sed -n 1p | sed -E "s/.*:v?//"; }
check_version() {
  local name=$1 have=$2 expected=$3
  [ "$have" = "$expected" ] || echo "warning: local $name $have, CI uses $expected" >&2
}
check_version swiftformat "$(swiftformat --version)" "$(want swiftformat)"
check_version swiftlint "$(swiftlint version)" "$(want swiftlint)"
check_version actionlint "$(actionlint --version | sed -n 1p)" "$(want actionlint)"
check_version gitleaks "$(gitleaks version | sed 's/^v//')" "$(want gitleaks)"

summary=()
step() {
  echo "== $1"
  shift
  "$@"
  summary+=("pass: $*")
}

step SwiftFormat swiftformat --lint .
step SwiftLint swiftlint lint --strict --quiet
step actionlint actionlint
step "Node tests" npm test
step OSV-Scanner scripts/osv-scan.sh
step gitleaks gitleaks git . --no-banner --redact

udid="$(scripts/pick-simulator.sh)"
trap 'xcrun simctl shutdown "$udid" 2>/dev/null || true' EXIT
log="build/ci-local.log"
mkdir -p build
echo "== Xcode: build, unit tests, UI tests (log: $log)"
SIM_UDID="$udid" XCODE_JOBS="${XCODE_JOBS:-2}" scripts/test.sh all > "$log" 2>&1 || { tail -40 "$log"; exit 1; }

device=$(xcrun simctl list devices -j | python3 -c '
import json, sys
udid = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["udid"] == udid:
            print(d["name"], "/", runtime.split(".")[-1].replace("iOS-", "iOS ").replace("-", "."))
' "$udid")
unit=$(grep -oE "Test run with [0-9]+ tests in [0-9]+ suites passed" "$log" | tail -1 | grep -oE "[0-9]+ tests" || echo "?")
ui=$(grep -cE "Test Case .* passed" "$log" || true)
xcode=$(xcodebuild -version | sed -n 1p)

echo
echo "Local CI: all green"
echo "- Simulator: $device ($xcode)"
echo "- Unit tests: $unit passed; UI tests: $ui passed"
echo "- SwiftFormat, SwiftLint --strict, actionlint, npm test, OSV-Scanner, gitleaks: pass"
