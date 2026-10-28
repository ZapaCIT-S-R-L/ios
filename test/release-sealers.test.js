// No fake sealer in a release build: every type that conforms to MessageSealer or CallKeySealer must sit inside
// `#if DEBUG` (UI-test stubs, demos), except the real ones, which conform to ReleaseMessageSealer /
// ReleaseCallKeySealer. The release build itself refuses to compile without a real sealer (LiveServices).
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { sealerProblems, sealerTypes } from "../scripts/release-sealers.js";

test("finds sealer types and whether they are debug-only", () => {
  const swift = `
    struct Real: ReleaseMessageSealer {}
    #if DEBUG
        struct Fake: MessageSealer {}
        #if os(iOS)
            final class Inner: CallKeySealer {}
        #endif
    #endif
    struct Leaked: Foo, CallKeySealer {}
  `;
  assert.deepEqual(sealerTypes(swift), [
    { name: "Real", debugOnly: false, release: true },
    { name: "Fake", debugOnly: true, release: false },
    { name: "Inner", debugOnly: true, release: false },
    { name: "Leaked", debugOnly: false, release: false },
  ]);
});

test("a fake sealer outside #if DEBUG is a problem", () => {
  assert.deepEqual(sealerProblems({ "a.swift": "struct Leaked: MessageSealer {}" }), [
    "a.swift: Leaked is a MessageSealer/CallKeySealer outside #if DEBUG and not a Release sealer",
  ]);
});

test("the app and its packages ship no fake sealer", () => {
  const root = fileURLToPath(new URL("..", import.meta.url));
  assert.deepEqual(sealerProblems(null, root), []);
});
