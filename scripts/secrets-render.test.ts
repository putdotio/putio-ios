import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const renderer = fileURLToPath(new URL("./secrets-render.jq", import.meta.url));
const example = fileURLToPath(new URL("../Config/Local.example.xcconfig", import.meta.url));

const render = (payload: unknown) => {
  const result = spawnSync("jq", ["-r", "-f", renderer], { encoding: "utf8", input: JSON.stringify(payload) });
  assert.equal(result.error, undefined, "jq must be installed");
  return result;
};

const payload = {
  PUTIO_CHROMECAST_RECEIVER_APP_ID: "AB12CD34",
  PUTIO_DEVELOPMENT_TEAM: "TEAM123456",
  PUTIO_OAUTH_CLIENT_ID: "1234",
};

const keys = (xcconfig: string) =>
  xcconfig
    .split("\n")
    .map((line) => /^([A-Z0-9_]+)\s*=/.exec(line)?.[1])
    .filter((key): key is string => key !== undefined);

test("renders every key of the iOS payload", () => {
  const result = render(payload);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(keys(result.stdout).sort(), Object.keys(payload).sort());
  assert.match(result.stdout, /^PUTIO_OAUTH_CLIENT_ID = 1234$/m);
});

test("renders only keys the example xcconfig documents", async () => {
  const { readFile } = await import("node:fs/promises");
  const documented = new Set(keys(await readFile(example, "utf8")));
  for (const key of Object.keys(payload)) assert.ok(documented.has(key), `${key} is missing from Config/Local.example.xcconfig`);
});

test("rejects a payload with keys outside the contract", () => {
  const result = render({ ...payload, PUTIO_SENTRY_DSN: "https://example.invalid/1" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /key inventory/);
});

test("rejects a payload with a missing key", () => {
  const { PUTIO_OAUTH_CLIENT_ID: _, ...missing } = payload;
  const result = render(missing);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /key inventory/);
});

test("rejects values that are blank, quoted or malformed", () => {
  for (const bad of [
    { PUTIO_DEVELOPMENT_TEAM: "  " },
    { PUTIO_DEVELOPMENT_TEAM: '"TEAM123456"' },
    { PUTIO_DEVELOPMENT_TEAM: "team" },
    { PUTIO_OAUTH_CLIENT_ID: "12a" },
    { PUTIO_CHROMECAST_RECEIVER_APP_ID: "AB12CD34; x" },
  ]) {
    const result = render({ ...payload, ...bad });
    assert.notEqual(result.status, 0, JSON.stringify(bad));
  }
});
