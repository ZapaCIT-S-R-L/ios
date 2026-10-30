// The `ios` job in ci.yml is the CI that replaces scripts/ci-local.sh for the Swift app: same Xcode and simulator
// generation as the developer Mac (Xcode 27.1, iOS 27), arm64, and the UI tests on every pull request.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { parse } from "yaml";

const workflow = parse(readFileSync(new URL("../.github/workflows/ci.yml", import.meta.url), "utf8"));
const ios = workflow.jobs.ios;

test("the ios job runs on the arm64 Xcode 27 image", () => {
  assert.equal(ios["runs-on"], "xcode-27");
});

test("the ios job pins Xcode 27.1, like the developer Mac", () => {
  assert.equal(ios.env.DEVELOPER_DIR, "/Applications/Xcode_27.1.app/Contents/Developer");
});

test("the simulator is chosen by scripts/pick-simulator.sh (newest iOS), not pinned to an old OS", () => {
  assert.equal(ios.env.SIM_DEVICE, undefined);
  assert.equal(ios.env.SIM_OS, undefined);
});

test("pull requests run the UI tests too, not only main", () => {
  const run = ios.steps.map((s) => s.run ?? "").find((r) => r.includes("scripts/test.sh"));
  assert.ok(run, "the ios job runs scripts/test.sh");
  assert.match(run, /scripts\/test\.sh all$/);
  assert.doesNotMatch(run, /\bunit\b/);
});

test("the xcresult bundles are uploaded when the job fails", () => {
  const upload = ios.steps.find((s) => (s.uses ?? "").startsWith("actions/upload-artifact@"));
  assert.equal(upload.if, "failure()");
  assert.equal(upload.with.path, "build/results");
});

test("a new push cancels a pull request's older run, and the token is read-only", () => {
  assert.match(workflow.concurrency["cancel-in-progress"], /pull_request/);
  assert.deepEqual(workflow.permissions, { contents: "read" });
});

test("every action is pinned by commit SHA", () => {
  const unpinned = Object.values(workflow.jobs)
    .flatMap((job) => job.steps ?? [])
    .map((step) => step.uses)
    .filter((uses) => uses && !/@[0-9a-f]{40}(\s|$)/.test(uses));
  assert.deepEqual(unpinned, []);
});
