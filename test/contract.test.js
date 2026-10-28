// Contract test: every request the app builds and every response its test fakes return (contract/fixtures/*.json)
// must match the API's openapi.yaml at the commit pinned in contract/api.json. The Swift tests check that the app
// builds exactly these requests and handles exactly these responses, so drift on either side fails here or there.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { parse } from "yaml";

const root = new URL("..", import.meta.url);
const pin = JSON.parse(await readFile(new URL("contract/api.json", root), "utf8"));

// The operations the app calls, and so must have fixtures (update with the Swift clients).
export const APP_OPERATIONS = [
  "POST /v1/auth/nonce",
  "POST /v1/auth/apple",
  "POST /v1/auth/google",
  "POST /v1/auth/logout",
  "GET /v1/me",
  "POST /v1/devices",
  "GET /v1/accounts/{accountId}/identity",
  "GET /v1/keys/prekeys",
  "POST /v1/attestation/challenge",
  "POST /v1/attestation/apple",
];

async function contract() {
  assert.match(pin.commit, /^[0-9a-f]{40}$/, "contract/api.json pins a full commit SHA");
  const cache = new URL(`build/contract/openapi-${pin.commit}.yaml`, root);
  let text;
  try {
    text = await readFile(cache, "utf8");
  } catch {
    const url = `https://raw.githubusercontent.com/${pin.repository}/${pin.commit}/${pin.file}`;
    const response = await fetch(url);
    assert.equal(response.status, 200, `fetch ${url}`);
    text = await response.text();
    await mkdir(new URL("build/contract/", root), { recursive: true });
    await writeFile(cache, text);
  }
  return parse(text);
}

const pointer = (...parts) => "/" + parts.map((p) => String(p).replaceAll("~", "~0").replaceAll("/", "~1")).join("/");

// Follows a local `$ref` (`#/components/...`) to the object and its JSON pointer.
function resolve(doc, node, path) {
  while (node && node.$ref) {
    path = node.$ref.slice(1);
    node = path
      .split("/")
      .slice(1)
      .reduce((value, key) => value[key.replaceAll("~1", "/").replaceAll("~0", "~")], doc);
  }
  return { node, path };
}

const doc = await contract();
const ajv = new Ajv2020({ strict: false, allErrors: true });
addFormats(ajv);
ajv.addSchema(doc, "openapi.json");

function validate(schemaPath, data, what) {
  const ok = ajv.validate({ $ref: `openapi.json#${schemaPath}` }, data);
  assert.ok(ok, `${what}: ${ajv.errorsText(ajv.errors)}`);
}

const fixtureNames = (await readdir(new URL("contract/fixtures/", root))).filter((n) => n.endsWith(".json")).sort();
const fixtures = await Promise.all(
  fixtureNames.map(async (name) => ({
    name,
    ...JSON.parse(await readFile(new URL(`contract/fixtures/${name}`, root), "utf8")),
  })),
);

test("every operation the app calls has a fixture", () => {
  const covered = new Set(fixtures.map((f) => f.operation));
  assert.deepEqual(APP_OPERATIONS.filter((op) => !covered.has(op)), []);
});

for (const fixture of fixtures) {
  test(`${fixture.name}: ${fixture.operation} ${fixture.response.status} matches the contract`, () => {
    const [method, path] = fixture.operation.split(" ");
    const operation = doc.paths?.[path]?.[method.toLowerCase()];
    assert.ok(operation, `${fixture.operation} is in openapi.yaml`);
    assert.notEqual(operation["x-status"], "draft", `${fixture.operation} is stable, not a draft`);
    const operationPath = pointer("paths", path, method.toLowerCase());

    if (fixture.request) {
      const body = resolve(doc, operation.requestBody, `${operationPath}/requestBody`);
      assert.ok(body.node?.content?.["application/json"], "the operation takes a JSON body");
      validate(`${body.path}/content/application~1json/schema`, fixture.request, "request");
    }

    for (const [name, value] of Object.entries(fixture.requestHeaders ?? {})) {
      const index = (operation.parameters ?? []).findIndex((p) => {
        const param = resolve(doc, p, "").node;
        return param.in === "header" && param.name.toLowerCase() === name.toLowerCase();
      });
      assert.ok(index >= 0, `request header ${name} is a parameter of ${fixture.operation}`);
      const param = resolve(doc, operation.parameters[index], `${operationPath}/parameters/${index}`);
      validate(`${param.path}/schema`, value, `request header ${name}`);
    }

    const status = String(fixture.response.status);
    assert.ok(operation.responses?.[status], `status ${status} is documented`);
    const response = resolve(doc, operation.responses[status], `${operationPath}/responses/${status}`);
    const json = response.node.content?.["application/json"];
    if (json) {
      validate(`${response.path}/content/application~1json/schema`, fixture.response.body, "response");
    } else {
      assert.equal(fixture.response.body, null, `status ${status} has no body`);
    }
    for (const [name, value] of Object.entries(fixture.response.headers ?? {})) {
      const header = response.node.headers?.[name];
      assert.ok(header, `header ${name} is documented`);
      const number = Number(value);
      validate(`${response.path}/headers/${name}/schema`, Number.isNaN(number) ? value : number, `header ${name}`);
    }
  });
}
