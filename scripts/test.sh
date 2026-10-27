#!/usr/bin/env bash
# Builds the app and runs the unit tests and the UI tests on a simulator, as CI does.
#   scripts/test.sh            build + unit + UI tests
#   scripts/test.sh unit       build + unit tests only
#   SIM_UDID=<udid> scripts/test.sh   use this simulator (xcrun simctl list devices)
#   XCODE_JOBS=2 scripts/test.sh      limit parallel compile jobs (busy machine)
# Simulator builds are signed ad hoc ("Sign to Run Locally"), so no Apple account or certificate is needed. They must
# be signed: an unsigned app has no entitlements and the Keychain refuses it (errSecMissingEntitlement, -34018).
set -euo pipefail
cd "$(dirname "$0")/.."
what="${1:-all}"
derived="${DERIVED_DATA:-build/DerivedData}"
results="${RESULTS_DIR:-build/results}"
udid="$(scripts/pick-simulator.sh)"
echo "Simulator: $udid"

xcodegen generate --quiet
# libsignal (Podfile). The prebuilt libsignal_ffi.a is fetched during the build and checked against its SHA-256.
pod install --silent
rm -rf "$results" && mkdir -p "$results"

common=(
  -workspace ZapaKid.xcworkspace -scheme ZapaKid
  -destination "platform=iOS Simulator,id=$udid"
  -derivedDataPath "$derived"
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
)
if [ -n "${XCODE_JOBS:-}" ]; then common+=(-jobs "$XCODE_JOBS" -parallel-testing-enabled NO); fi

# Shared Mac: don't build while an Android emulator runs (the Android repo waits for xcodebuild the same way).
if [ -z "${CI:-}" ]; then
  while pgrep -f 'qemu-system|(^|/)emulator( |$)' >/dev/null; do
    echo "An Android emulator is running; waiting 30 s before building..."
    sleep 30
  done
fi
xcodebuild build-for-testing "${common[@]}" -quiet
xcodebuild test-without-building "${common[@]}" -only-testing:ZapaKidTests \
  -resultBundlePath "$results/unit.xcresult"
if [ "$what" = "all" ]; then
  xcodebuild test-without-building "${common[@]}" -only-testing:ZapaKidUITests \
    -resultBundlePath "$results/ui.xcresult"
fi
