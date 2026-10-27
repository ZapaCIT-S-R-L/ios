// libsignal comes from Signal's CocoaPod, pinned to one release tag, with Signal's prebuilt libsignal_ffi.a checked
// against the SHA-256 from that release (libsignal-client-ios-build-vX.Y.Z.tar.gz.sha256). Bumps are manual PRs
// (Dependabot has no CocoaPods support): see CONTRIBUTING.md.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("the Podfile pins LibSignalClient to a release tag from Signal's repository", () => {
  const podfile = read("Podfile");
  const pod = podfile.match(/pod 'LibSignalClient', git: '([^']+)', tag: '(v\d+\.\d+\.\d+)'/);
  assert.ok(pod, "pod 'LibSignalClient', git: ..., tag: 'vX.Y.Z'");
  assert.equal(pod[1], "https://github.com/signalapp/libsignal.git");
});

test("the prebuilt library is checked against a SHA-256", () => {
  assert.match(read("Podfile"), /ENV\['LIBSIGNAL_FFI_PREBUILD_CHECKSUM'\] = '[0-9a-f]{64}'/);
});

test("Podfile.lock is committed and agrees with the Podfile tag", () => {
  assert.ok(existsSync(new URL("../Podfile.lock", import.meta.url)));
  const tag = read("Podfile").match(/tag: '(v[\d.]+)'/)[1];
  assert.match(read("Podfile.lock"), new RegExp(`LibSignalClient \\(${tag.slice(1).replaceAll(".", "\\.")}\\)`));
});
