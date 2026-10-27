// Finds the user-facing strings in the Swift sources and checks them against the String Catalogs.
// Every string shown to people must be in a catalog, translated into every app language (RO, EN, DE).
//   node scripts/strings.js   prints missing keys and translations, exits 1 if any
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export const LANGUAGES = ["en", "ro", "de"];

// Catalog and the Swift sources whose strings it holds (the app, and the ZapaKidKit package with bundle: .module).
export const CATALOGS = [
  { catalog: "ZapaKid/Localizable.xcstrings", sources: ["ZapaKid"] },
  { catalog: "ZapaKidKit/Sources/ZapaKidKit/Localizable.xcstrings", sources: ["ZapaKidKit/Sources"] },
  { catalog: "ZapaCalls/Sources/ZapaCalls/Localizable.xcstrings", sources: ["ZapaCalls/Sources"] },
];

// SwiftUI views and String(localized:) take a literal as the localization key. `\(x)` becomes `%lld` (all
// interpolations in this app are integers; add a case here when that changes).
const PATTERNS = [
  /\b(?:Text|Label|Button|navigationTitle|accessibilityLabel|accessibilityHint)\(\s*"((?:[^"\\]|\\.)*)"/g,
  /String\(\s*localized:\s*"((?:[^"\\]|\\.)*)"/g,
];

export function keysIn(swift) {
  const withoutComments = swift.replace(/\/\/.*$/gm, "");
  const keys = new Set();
  for (const pattern of PATTERNS) {
    for (const match of withoutComments.matchAll(pattern)) {
      keys.add(match[1].replace(/\\\([^)]*\)/g, "%lld").replace(/\\"/g, '"'));
    }
  }
  return keys;
}

// Keys whose text must not be translated (brand names).
const VERBATIM = new Set(["ZapaKid"]);

export function problems(keys, catalog) {
  const found = [];
  const strings = catalog.strings ?? {};
  for (const key of keys) {
    const entry = strings[key];
    if (!entry) {
      found.push(`missing key: ${JSON.stringify(key)}`);
      continue;
    }
    if (VERBATIM.has(key)) continue;
    for (const language of LANGUAGES.filter((l) => l !== catalog.sourceLanguage)) {
      const localization = entry.localizations?.[language];
      // A plain string, or plural variations (one, few, other...): every form must be translated.
      const units = localization?.variations?.plural
        ? Object.values(localization.variations.plural).map((form) => form.stringUnit)
        : [localization?.stringUnit];
      if (units.some((unit) => !unit || unit.state !== "translated" || !unit.value)) {
        found.push(`not translated into ${language}: ${JSON.stringify(key)}`);
      }
    }
  }
  return found;
}

function swiftFiles(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return swiftFiles(path);
    return name.endsWith(".swift") ? [path] : [];
  });
}

export function check(root) {
  return CATALOGS.flatMap(({ catalog, sources }) => {
    const keys = new Set(
      sources.flatMap((dir) => swiftFiles(join(root, dir))).flatMap((file) => [...keysIn(readFileSync(file, "utf8"))]),
    );
    const parsed = JSON.parse(readFileSync(join(root, catalog), "utf8"));
    return problems(keys, parsed).map((p) => `${catalog}: ${p}`);
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const found = check(fileURLToPath(new URL("..", import.meta.url)));
  for (const line of found) console.error(line);
  if (found.length) process.exit(1);
  console.log("Strings: every key is in a catalog and translated into RO and DE.");
}
