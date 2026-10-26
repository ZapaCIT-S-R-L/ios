// The app's bundle ID is ro.zapakid.app (team 9572LYGZ7S) since 2026-10-26. The old ID must not come back anywhere:
// not in the project, entitlements, Keychain service names, App Attest, tests or docs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
// Built from parts so this file doesn't contain what it looks for.
const OLD = ["com", "zapacit", "cuzaai"].join(".");
const OLD_PREFIX = ["com", "zapacit", ""].join(".");

const tracked = execFileSync("git", ["ls-files", "-z"], { cwd: root, encoding: "utf8" })
  .split("\0")
  .filter((path) => path && !/\.(png|jpe?g|pdf)$/i.test(path));

test("no file mentions the old bundle ID or the com.zapacit prefix", () => {
  const offenders = tracked.filter((path) => {
    const text = readFileSync(new URL(path, `file://${root}/`), "utf8");
    return text.includes(OLD) || text.includes(OLD_PREFIX);
  });
  assert.deepEqual(offenders, []);
});

test("project.yml uses ro.zapakid.app and the ro.zapakid prefix", () => {
  const project = readFileSync(new URL("project.yml", `file://${root}/`), "utf8");
  assert.match(project, /bundleIdPrefix: ro\.zapakid\n/);
  const ids = [...project.matchAll(/PRODUCT_BUNDLE_IDENTIFIER: (\S+)/g)].map((m) => m[1]);
  assert.ok(ids.length >= 3);
  for (const id of ids) assert.match(id, /^ro\.zapakid\.app(\.[a-z]+)?$/);
  assert.ok(ids.includes("ro.zapakid.app"));
});
