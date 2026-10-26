#!/usr/bin/env bash
# Builds the app and runs the unit tests and the UI tests on a simulator, as CI does.
#   scripts/test.sh            build + unit + UI tests
#   scripts/test.sh unit       build + unit tests only
#   SIM_UDID=<udid> scripts/test.sh   use this simulator (xcrun simctl list devices)
# Simulator builds are not code signed, so no Apple account or certificate is needed.
set -euo pipefail
cd "$(dirname "$0")/.."
what="${1:-all}"
derived="${DERIVED_DATA:-build/DerivedData}"
results="${RESULTS_DIR:-build/results}"
udid="$(scripts/pick-simulator.sh)"
echo "Simulator: $udid"

xcodegen generate --quiet
rm -rf "$results" && mkdir -p "$results"

common=(
  -project ZapaKid.xcodeproj -scheme ZapaKid
  -destination "platform=iOS Simulator,id=$udid"
  -derivedDataPath "$derived"
  CODE_SIGNING_ALLOWED=NO
)

xcodebuild build-for-testing "${common[@]}" -quiet
xcodebuild test-without-building "${common[@]}" -only-testing:ZapaKidTests \
  -resultBundlePath "$results/unit.xcresult"
if [ "$what" = "all" ]; then
  xcodebuild test-without-building "${common[@]}" -only-testing:ZapaKidUITests \
    -resultBundlePath "$results/ui.xcresult"
fi
