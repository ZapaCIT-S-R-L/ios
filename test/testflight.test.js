// The TestFlight workflow: signed upload from main only, in the protected `testflight` environment, skipping with a
// clear message until Stefan adds the secrets. Manual signing (Stefan's choice): an App Manager API key for the upload,
// plus the distribution certificate (.p12) and the App Store profile. All exist on the runner only during the job.
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
  assert.deepEqual([...new Set(secrets)], [
    "ASC_ISSUER_ID",
    "ASC_KEY_ID",
    "ASC_KEY_P8",
    "DIST_CERT_P12",
    "DIST_CERT_PASSWORD",
    "PROVISIONING_PROFILE",
  ]);
  assert.deepEqual(workflow.permissions, { contents: "read" });
});

test("skips with a clear message until the key exists", () => {
  const check = step("Check the signing secrets");
  assert.ok(check, "a step checks the secrets first");
  assert.match(check.run, /::notice/);
  for (const later of steps.slice(steps.indexOf(check) + 1)) {
    assert.match(later.if ?? "", /steps\.key\.outputs\.ready == 'true'/, `${later.name ?? later.uses} waits for the key`);
  }
});

test("the check needs all six secrets", () => {
  const check = step("Check the signing secrets");
  for (const name of ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "DIST_CERT_P12", "DIST_CERT_PASSWORD", "PROVISIONING_PROFILE"]) {
    assert.match(check.run, new RegExp(`\\$${name}\\b`), `${name} is checked`);
  }
});

test("signing is manual, with the certificate in a temporary keychain", () => {
  const install = step("Install the certificate and profile");
  assert.ok(install);
  assert.match(install.run, /security create-keychain/);
  assert.match(install.run, /umask 077/);
  const archive = step("Archive (signed, Release)");
  assert.match(archive.run, /ZK_CODE_SIGN_STYLE=Manual/);
  assert.match(archive.run, /ZK_PROVISIONING_PROFILE=/);
  assert.doesNotMatch(archive.run, /-allowProvisioningUpdates/, "no cloud signing with an App Manager key");
});

test("the key, certificate, keychain and profile are removed whatever happens", () => {
  const cleanup = step("Remove the signing files");
  assert.ok(cleanup);
  assert.match(cleanup.if, /always\(\)/);
  assert.match(cleanup.run, /security delete-keychain/);
  assert.match(cleanup.run, /rm -f/);
  assert.match(cleanup.run, /mobileprovision/);
});

test("actions are pinned by commit SHA", () => {
  for (const s of steps.filter((s) => s.uses)) {
    assert.match(s.uses, /@[0-9a-f]{40}$/, s.uses);
  }
});

test("never prints a secret", () => {
  for (const name of ["ASC_KEY_P8", "DIST_CERT_P12", "DIST_CERT_PASSWORD", "PROVISIONING_PROFILE"]) {
    assert.doesNotMatch(text, new RegExp(`echo\\s+"?\\$\\{?${name}`), `${name} is never echoed to the log`);
  }
  assert.doesNotMatch(text, /set -x/);
});
