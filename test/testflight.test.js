// The TestFlight workflow: signed upload from main only, in the protected `testflight` environment, skipping with a
// clear message until Stefan adds the App Store Connect API key. The key exists on the runner only for the upload.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { parse } from "yaml";

const text = readFileSync(new URL("../.github/workflows/testflight.yml", import.meta.url), "utf8");
const workflow = parse(text);
const job = workflow.jobs.upload;
const steps = job.steps;
const step = (name) => steps.find((s) => s.name === name);

test("runs on pushes to main and by hand, nothing else", () => {
  assert.deepEqual(Object.keys(workflow.on).sort(), ["push", "workflow_dispatch"]);
  assert.deepEqual(workflow.on.push.branches, ["main"]);
  assert.match(job.if, /github\.ref == 'refs\/heads\/main'/, "a manual run from another branch does nothing");
});

test("uses the protected testflight environment and reads only its own secrets", () => {
  assert.equal(job.environment, "testflight");
  const secrets = [...text.matchAll(/secrets\.([A-Z0-9_]+)/g)].map((m) => m[1]).sort();
  assert.deepEqual([...new Set(secrets)], ["ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_KEY_P8"]);
  assert.deepEqual(workflow.permissions, { contents: "read" });
});

test("skips with a clear message until the key exists", () => {
  const check = step("Check the App Store Connect key");
  assert.ok(check, "a step checks the secrets first");
  assert.match(check.run, /::notice/);
  for (const later of steps.slice(steps.indexOf(check) + 1)) {
    assert.match(later.if ?? "", /steps\.key\.outputs\.ready == 'true'/, `${later.name ?? later.uses} waits for the key`);
  }
});

test("the key file is removed whatever happens", () => {
  const cleanup = step("Remove the key");
  assert.ok(cleanup);
  assert.match(cleanup.if, /always\(\)/);
  assert.match(cleanup.run, /rm -f/);
});

test("actions are pinned by commit SHA", () => {
  for (const s of steps.filter((s) => s.uses)) {
    assert.match(s.uses, /@[0-9a-f]{40}$/, s.uses);
  }
});

test("never prints the key", () => {
  assert.doesNotMatch(text, /echo\s+"?\$\{?ASC_KEY_P8/, "the key is only piped to a file, never echoed to the log");
  assert.doesNotMatch(text, /set -x/);
});
