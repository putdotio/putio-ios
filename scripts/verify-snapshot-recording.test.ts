import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { verifyRecording } from "./verify-snapshot-recording.ts";

function testCase(result: string, ...failures: string[]) {
  return {
    nodeType: "Test Case",
    name: "testWalk()",
    result,
    children: failures.map((name) => ({ nodeType: "Failure Message", name })),
  };
}

function payload(...cases: object[]) {
  return { testNodes: [{ nodeType: "Unit test bundle", name: "PutioUITests", children: cases }] };
}

describe("verifyRecording", () => {
  test("accepts a run whose only failures are record-mode assertions", () => {
    const verdict = verifyRecording(
      payload(testCase("Failed", "Record mode is on. Automatically recorded snapshot", "No reference was found on disk")),
    );
    assert.deepEqual(verdict, { ok: true });
  });

  test("lists every unexpected failure", () => {
    const verdict = verifyRecording(payload(testCase("Failed", "Record mode is on", "App crashed", "Timed out")));
    assert.deepEqual(verdict, {
      ok: false,
      messages: ["Unexpected failures during snapshot recording:", "  App crashed", "  Timed out"],
    });
  });

  test("ignores skip reasons on a skipped case but does not count it as run", () => {
    const verdict = verifyRecording(payload(testCase("Skipped", "Needs a signed-in account")));
    assert.equal(verdict.ok, false);
    assert.match(verdict.ok ? "" : (verdict.messages[0] ?? ""), /^No test cases found/);
  });

  test("fails closed on a payload without test nodes", () => {
    const verdict = verifyRecording({});
    assert.match(verdict.ok ? "" : (verdict.messages[0] ?? ""), /^No test cases found/);
  });

  test("fails closed when record mode never fired", () => {
    const verdict = verifyRecording(payload(testCase("Passed")));
    assert.match(verdict.ok ? "" : (verdict.messages[0] ?? ""), /^No record-mode snapshot assertions found/);
  });
});
