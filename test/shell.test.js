// Shell scripts run with `set -o pipefail`: `cmd | head` can kill cmd with SIGPIPE and fail the script (exit 141),
// at random. That happened in scripts/ci-local.sh on 2026-10-26. Use `sed -n 1p`, which reads all its input.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

const dir = new URL("../scripts/", import.meta.url);

test("no `| head` in pipefail scripts", () => {
  const offenders = readdirSync(dir)
    .filter((name) => name.endsWith(".sh"))
    .filter((name) => {
      const text = readFileSync(new URL(name, dir), "utf8");
      return /pipefail/.test(text) && /\|\s*head\b/.test(text);
    });
  assert.deepEqual(offenders, []);
});
