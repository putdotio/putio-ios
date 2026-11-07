#!/usr/bin/env node

import { readFileSync } from "node:fs";
import process from "node:process";

const ACCEPTED = /Record mode is on|No reference was found on disk/;

type TestNode = {
  nodeType?: unknown;
  name?: unknown;
  result?: unknown;
  children?: TestNode[] | null;
};

export type Verdict = { ok: true } | { ok: false; messages: string[] };

function walk(
  nodes: TestNode[],
  enclosingResult: unknown,
  visit: (node: TestNode, result: unknown) => void,
): void {
  for (const node of nodes) {
    const result = node.nodeType === "Test Case" ? node.result : enclosingResult;
    visit(node, result);
    walk(node.children || [], result, visit);
  }
}

function text(value: unknown): string {
  return value === null || value === undefined ? "" : String(value);
}

export function verifyRecording(payload: unknown): Verdict {
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
    throw new TypeError("xcresulttool payload must be a JSON object");
  }
  const unexpected: string[] = [];
  let testsSeen = 0;
  let recordingsSeen = 0;

  walk((payload as { testNodes?: TestNode[] | null }).testNodes || [], undefined, (node, enclosingResult) => {
    if (node.nodeType === "Test Case" && enclosingResult !== "Skipped") testsSeen += 1;
    if (node.nodeType !== "Failure Message") return;
    if (enclosingResult === "Skipped") return;

    if (ACCEPTED.test(text(node.name))) {
      recordingsSeen += 1;
    } else {
      unexpected.push(text(node.name));
    }
  });

  if (unexpected.length > 0) {
    return {
      ok: false,
      messages: ["Unexpected failures during snapshot recording:", ...unexpected.map((message) => `  ${message}`)],
    };
  }
  if (testsSeen === 0) {
    return {
      ok: false,
      messages: [
        "No test cases found in the result payload; the run never executed tests (or the xcresulttool schema changed).",
      ],
    };
  }
  if (recordingsSeen === 0) {
    return {
      ok: false,
      messages: ["No record-mode snapshot assertions found; record mode was not active, so no baselines were written."],
    };
  }
  return { ok: true };
}

if (import.meta.main) {
  const verdict = verifyRecording(JSON.parse(readFileSync(0, "utf8")));
  if (!verdict.ok) {
    for (const message of verdict.messages) console.error(message);
    process.exitCode = 1;
  }
}
