// Tests for scripts/strings.js, and the real check: every user-facing string is translated into RO and DE.
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { check, keysIn, problems } from "../scripts/strings.js";

test("finds SwiftUI and String(localized:) literals, interpolation as %lld", () => {
  const swift = `
    Text("Sign out")
    Label("Sign in with Google", systemImage: "g.circle")
    .accessibilityHint(Text("Signs out on this phone"))
    String(localized: "Try again in \\(seconds) seconds.")
    let notShown = "plain string"
    // Text("in a comment")
    Text(
        "on the next line"
    )
  `;
  assert.deepEqual(
    [...keysIn(swift)].sort(),
    ["Sign in with Google", "Sign out", "Signs out on this phone", "Try again in %lld seconds.", "on the next line"],
  );
});

const catalog = {
  sourceLanguage: "en",
  strings: {
    "Sign out": {
      localizations: {
        ro: { stringUnit: { state: "translated", value: "Deconectare" } },
        de: { stringUnit: { state: "translated", value: "Abmelden" } },
      },
    },
    "Half done": { localizations: { ro: { stringUnit: { state: "translated", value: "Pe jumătate" } } } },
    "Needs review": {
      localizations: {
        ro: { stringUnit: { state: "needs_review", value: "x" } },
        de: { stringUnit: { state: "translated", value: "y" } },
      },
    },
    ZapaKid: {},
  },
};

test("a translated key passes; brand names need no translation", () => {
  assert.deepEqual(problems(new Set(["Sign out", "ZapaKid"]), catalog), []);
});

test("a key missing from the catalog is reported", () => {
  assert.deepEqual(problems(new Set(["Nope"]), catalog), ['missing key: "Nope"']);
});

test("a missing or unreviewed translation is reported", () => {
  assert.deepEqual(problems(new Set(["Half done", "Needs review"]), catalog), [
    'not translated into de: "Half done"',
    'not translated into ro: "Needs review"',
  ]);
});

test("the app's strings are all translated into RO and DE", () => {
  assert.deepEqual(check(fileURLToPath(new URL("..", import.meta.url))), []);
});
