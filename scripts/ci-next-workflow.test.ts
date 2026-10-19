import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { parse } from "yaml";

type RecordValue = Record<string, unknown>;

const workflowUrl = (name: string): URL =>
  new URL(`../.github/workflows/${name}`, import.meta.url);

const asRecord = (value: unknown, context: string): RecordValue => {
  assert.equal(typeof value, "object", `${context} must be an object`);
  assert.notEqual(value, null, `${context} must not be null`);
  assert.equal(Array.isArray(value), false, `${context} must not be an array`);
  return value as RecordValue;
};

const recordAt = (record: RecordValue, key: string, context: string): RecordValue =>
  asRecord(record[key], `${context}.${key}`);

const arrayAt = (record: RecordValue, key: string, context: string): readonly unknown[] => {
  const value = record[key];
  assert.equal(Array.isArray(value), true, `${context}.${key} must be an array`);
  return value as readonly unknown[];
};

const stringAt = (record: RecordValue, key: string, context: string): string => {
  const value = record[key];
  assert.equal(typeof value, "string", `${context}.${key} must be a string`);
  return value as string;
};

const loadWorkflow = async (name: string): Promise<RecordValue> =>
  asRecord(parse(await readFile(workflowUrl(name), "utf8")) as unknown, name);

test("next CI admits rollout PR bases without broadening push", async () => {
  const workflow = await loadWorkflow("ci-next.yml");
  assert.equal(workflow.name, "Next CI");
  assert.match(stringAt(workflow, "run-name", "ci-next.yml"), /^Next app CI/);

  const triggers = recordAt(workflow, "on", "ci-next.yml");
  const pullRequest = recordAt(triggers, "pull_request", "ci-next.yml.on");
  assert.deepEqual(arrayAt(pullRequest, "branches", "ci-next.yml.on.pull_request"), [
    "next",
    "next-rollout/**",
  ]);

  const push = recordAt(triggers, "push", "ci-next.yml.on");
  assert.deepEqual(arrayAt(push, "branches", "ci-next.yml.on.push"), ["next"]);

  const jobs = recordAt(workflow, "jobs", "ci-next.yml");
  assert.deepEqual(Object.keys(jobs), ["changes", "markdown", "app-store", "checks", "tvos", "ios", "build", "proof"]);
});

type GitHubContext = Readonly<{ event_name: string; ref: string; run_id: string }>;

// Covers the expression subset concurrency settings use (`github.*`, quoted
// strings, `==`, `!=`, `&&`, `||`, `!`), which GitHub and JavaScript evaluate
// alike for these values.
const evaluate = (value: unknown, github: GitHubContext): unknown => {
  if (typeof value !== "string") return value;
  const run = (expression: string): unknown => {
    assert.match(expression, /^[\w.\s'=!&|]+$/, `unsupported expression: ${expression}`);
    return new Function("github", `return (${expression});`)(github) as unknown;
  };
  const whole = /^\$\{\{([^}]*)\}\}$/.exec(value);
  if (whole) return run(whole[1] ?? "");
  return value.replace(/\$\{\{([^}]*)\}\}/g, (_, expression: string) => String(run(expression)));
};

test("next CI cancels a stale pull request run but never a push to next", async () => {
  const workflow = await loadWorkflow("ci-next.yml");
  const concurrency = recordAt(workflow, "concurrency", "ci-next.yml");
  const settle = (github: GitHubContext) => ({
    group: evaluate(concurrency.group, github),
    cancelInProgress: evaluate(concurrency["cancel-in-progress"], github),
  });
  const push = (runId: string) => settle({ event_name: "push", ref: "refs/heads/next", run_id: runId });
  const pullRequest = (runId: string) =>
    settle({ event_name: "pull_request", ref: "refs/pull/7/merge", run_id: runId });

  // A shared group would let a later push cancel, or replace while queued, an
  // earlier one, so that merged commit would get no result of its own.
  assert.notEqual(push("1").group, push("2").group);
  assert.notEqual(push("1").group, pullRequest("2").group);
  assert.equal(pullRequest("3").group, pullRequest("4").group);
  assert.equal(pullRequest("4").cancelInProgress, true);
});
