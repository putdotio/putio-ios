import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import test from "node:test";

import { parse } from "yaml";

type RecordValue = Record<string, unknown>;

const workflowsUrl = new URL("../.github/workflows/", import.meta.url);

// A pull request from a fork runs on GitHub-hosted runners; everything else in
// this repository runs where ci-failover's repository variable points, or on
// GitHub-hosted runners while the variable is unset.
const fromFork =
  "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository";
const poolRunners: Readonly<Record<string, string>> = {
  linux: `\${{ ${fromFork} && 'ubuntu-24.04-arm' || vars.CI_RUNNER_ARM64 || 'ubuntu-24.04-arm' }}`,
  macos: `\${{ ${fromFork} && 'macos-26' || vars.CI_RUNNER_MACOS || 'macos-26' }}`,
};

// Events whose runs execute trusted code from this repository, or a fork's
// pull request that the guard above sends to GitHub-hosted runners.
const poolEvents = new Set(["pull_request", "push", "workflow_dispatch", "workflow_call", "release"]);

const asRecord = (value: unknown, context: string): RecordValue => {
  assert.equal(typeof value, "object", `${context} must be an object`);
  assert.notEqual(value, null, `${context} must not be null`);
  assert.equal(Array.isArray(value), false, `${context} must not be an array`);
  return value as RecordValue;
};

// A self-hosted label, or anything the workflow computes, can reach the pool.
const reachesPool = (runsOn: unknown): boolean =>
  typeof runsOn !== "string" || runsOn.includes("${{") || /zebroid|self-hosted/.test(runsOn);

const runnerViolations = (name: string, source: string): string[] => {
  const workflow = asRecord(parse(source) as unknown, name);
  const on = workflow.on;
  const events = typeof on === "string" ? [on] : Array.isArray(on) ? on.map(String) : Object.keys(asRecord(on, `${name}.on`));
  const jobs = asRecord(workflow.jobs, `${name}.jobs`);
  const violations: string[] = [];
  for (const [id, value] of Object.entries(jobs)) {
    const runsOn = asRecord(value, `${name}.jobs.${id}`)["runs-on"];
    if (runsOn === undefined || !reachesPool(runsOn)) {
      continue;
    }
    if (!Object.values(poolRunners).includes(runsOn as string)) {
      violations.push(`${name} ${id}: runs-on must be one of the fork-guarded pool runners`);
    }
    for (const event of events.filter((event) => !poolEvents.has(event))) {
      violations.push(`${name} ${id}: ${event} can run untrusted code on the pool`);
    }
  }
  return violations;
};

test("pool jobs send fork pull requests to GitHub-hosted runners", async () => {
  const names = (await readdir(workflowsUrl)).filter((name) => /\.ya?ml$/.test(name));
  assert.notEqual(names.length, 0);
  const violations = (
    await Promise.all(names.map(async (name) => runnerViolations(name, await readFile(new URL(name, workflowsUrl), "utf8"))))
  ).flat();
  assert.deepEqual(violations, []);
});

test("an unguarded or untrusted pool job is a violation", () => {
  const workflow = (on: string, runsOn: string): string =>
    `on: ${on}\njobs:\n  build:\n    runs-on: ${JSON.stringify(runsOn)}\n    steps: []\n`;
  assert.deepEqual(runnerViolations("hosted.yml", workflow("pull_request", "macos-26")), []);
  assert.deepEqual(runnerViolations("guarded.yml", workflow("pull_request", poolRunners.macos)), []);
  assert.equal(runnerViolations("label.yml", workflow("pull_request", "zebroid-macos")).length, 1);
  assert.equal(runnerViolations("variable.yml", workflow("pull_request", "${{ vars.CI_RUNNER_MACOS }}")).length, 1);
  assert.equal(runnerViolations("target.yml", workflow("pull_request_target", poolRunners.linux)).length, 1);
  assert.equal(runnerViolations("comment.yml", workflow("[issue_comment]", poolRunners.linux)).length, 1);
});
