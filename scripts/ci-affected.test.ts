import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = fileURLToPath(new URL("..", import.meta.url));

const classify = (paths: string[]) =>
  Object.fromEntries(
    execFileSync("sh", ["scripts/ci-affected.sh"], {
      cwd: root,
      encoding: "utf8",
      input: `${paths.join("\n")}\n`,
    })
      .trim()
      .split("\n")
      .map((line) => line.split("=")),
  );

test("tested Ruby tooling in verify-fast runs both CI lanes", () => {
  assert.deepEqual(classify(["scripts/sync-phosphor-icons.test.rb"]), {
    app: "true",
    tooling: "true",
  });
});

test("snapshot verifier changes run their focused tooling tests", () => {
  assert.deepEqual(classify(["scripts/verify-snapshot-recording.rb"]), {
    app: "false",
    tooling: "true",
  });
});

test("unclassified Ruby scripts use the conservative app fallback", () => {
  assert.deepEqual(classify(["scripts/sync-brand-fonts.rb"]), {
    app: "true",
    tooling: "false",
  });
});

test("Node-only tooling changes skip the app lane", () => {
  assert.deepEqual(classify(["scripts/vref-manifest.test.ts"]), {
    app: "false",
    tooling: "true",
  });
});

test("documentation-only changes skip both lanes", () => {
  assert.deepEqual(classify(["docs/example.md"]), {
    app: "false",
    tooling: "false",
  });
});
