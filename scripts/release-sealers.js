// Finds every MessageSealer / CallKeySealer in the Swift sources that ship in the app and checks that fakes are
// Debug-only (inside `#if DEBUG`). Real sealers conform to ReleaseMessageSealer / ReleaseCallKeySealer.
//   node scripts/release-sealers.js   prints problems, exits 1 if any
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export const SOURCES = ["ZapaKid", "ZapaKidKit/Sources", "ZapaCalls/Sources", "ZapaChat/Sources"];
const DECLARATION = /^\s*(?:(?:public|private|fileprivate|internal|final|open)\s+)*(?:struct|class|actor|enum|extension)\s+(\w+)[^{]*?:\s*([^{]+)\{?/;

export function sealerTypes(swift) {
  const found = [];
  const stack = []; // one entry per open #if: is it `#if DEBUG`?
  for (const raw of swift.split("\n")) {
    const line = raw.replace(/\/\/.*$/, "");
    const directive = line.trim();
    if (directive.startsWith("#if")) {
      stack.push(/^#if\s+DEBUG\b/.test(directive));
      continue;
    }
    if (directive.startsWith("#else") || directive.startsWith("#elseif")) {
      if (stack.length) stack[stack.length - 1] = false;
      continue;
    }
    if (directive.startsWith("#endif")) {
      stack.pop();
      continue;
    }
    const match = line.match(DECLARATION);
    if (!match) continue;
    const conformances = match[2].split(",").map((name) => name.trim().split(/[\s<]/)[0]);
    const release = conformances.some((name) => /^Release(Message|CallKey)Sealer$/.test(name));
    if (!release && !conformances.some((name) => /^(MessageSealer|CallKeySealer)$/.test(name))) continue;
    found.push({ name: match[1], debugOnly: stack.includes(true), release });
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

/** `files`: {path: source}, or null to read SOURCES under `root`. */
export function sealerProblems(files, root) {
  const sources = files ?? Object.fromEntries(
    SOURCES.flatMap((dir) => swiftFiles(join(root, dir))).map((path) => [path.slice(root.length), readFileSync(path, "utf8")]),
  );
  return Object.entries(sources).flatMap(([path, swift]) =>
    sealerTypes(swift)
      .filter((type) => !type.debugOnly && !type.release)
      .map((type) => `${path}: ${type.name} is a MessageSealer/CallKeySealer outside #if DEBUG and not a Release sealer`),
  );
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const problems = sealerProblems(null, fileURLToPath(new URL("..", import.meta.url)));
  for (const line of problems) console.error(line);
  if (problems.length) process.exit(1);
  console.log("Sealers: no fake sealer outside #if DEBUG.");
}
