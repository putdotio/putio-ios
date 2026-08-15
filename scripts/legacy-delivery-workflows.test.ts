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

const stringAt = (record: RecordValue, key: string, context: string): string => {
  const value = record[key];
  assert.equal(typeof value, "string", `${context}.${key} must be a string`);
  return value as string;
};

const loadWorkflow = async (name: string): Promise<RecordValue> =>
  asRecord(parse(await readFile(workflowUrl(name), "utf8")) as unknown, name);

const dispatchInputs = (workflow: RecordValue, name: string): RecordValue => {
  const on = recordAt(workflow, "on", name);
  assert.deepEqual(Object.keys(on), ["workflow_dispatch"]);
  return recordAt(recordAt(on, "workflow_dispatch", `${name}.on`), "inputs", `${name}.on.workflow_dispatch`);
};

test("legacy beta is a clearly bounded default-branch entrypoint", async () => {
  const workflow = await loadWorkflow("beta.yml");
  assert.equal(workflow.name, "Legacy iOS 3.x Beta");
  assert.match(stringAt(workflow, "run-name", "beta.yml"), /legacy iOS 3\.x beta.*protected main/i);

  const inputs = dispatchInputs(workflow, "beta.yml");
  assert.deepEqual(Object.keys(inputs), [
    "legacy_ref",
    "changelog",
    "groups",
    "processing_timeout_minutes",
  ]);
  const legacyRef = recordAt(inputs, "legacy_ref", "beta.yml inputs");
  assert.deepEqual(legacyRef.options, ["refs/heads/main"]);
  assert.equal(legacyRef.default, "refs/heads/main");

  const permissions = recordAt(workflow, "permissions", "beta.yml");
  assert.deepEqual(permissions, { actions: "write", contents: "read" });
  const dispatch = recordAt(recordAt(workflow, "jobs", "beta.yml"), "dispatch", "beta.yml jobs");
  assert.equal(dispatch.uses, "./.github/workflows/legacy-ios-dispatch.yml");
  assert.equal(recordAt(dispatch, "with", "beta.yml dispatch").operation, "beta");
  assert.equal("environment" in dispatch, false);
});

test("legacy release requires an explicit legacy version", async () => {
  const workflow = await loadWorkflow("release.yml");
  assert.equal(workflow.name, "Legacy iOS 3.x Release");
  assert.match(stringAt(workflow, "run-name", "release.yml"), /legacy iOS 3\.x release.*protected main/i);

  const inputs = dispatchInputs(workflow, "release.yml");
  assert.deepEqual(Object.keys(inputs), ["legacy_ref", "version"]);
  const legacyRef = recordAt(inputs, "legacy_ref", "release.yml inputs");
  assert.deepEqual(legacyRef.options, ["refs/heads/main"]);
  assert.equal(legacyRef.default, "refs/heads/main");
  assert.equal(recordAt(inputs, "version", "release.yml inputs").required, true);

  const dispatch = recordAt(recordAt(workflow, "jobs", "release.yml"), "dispatch", "release.yml jobs");
  assert.equal(dispatch.uses, "./.github/workflows/legacy-ios-dispatch.yml");
  assert.equal(recordAt(dispatch, "with", "release.yml dispatch").operation, "release");
  assert.equal("environment" in dispatch, false);
});

test("the relay fails closed before dispatching the reviewed main workflows", async () => {
  const workflow = await loadWorkflow("legacy-ios-dispatch.yml");
  assert.equal(workflow.name, "Legacy iOS 3.x dispatch contract");
  const on = recordAt(workflow, "on", "legacy-ios-dispatch.yml");
  assert.deepEqual(Object.keys(on), ["workflow_call"]);
  assert.deepEqual(recordAt(workflow, "permissions", "legacy-ios-dispatch.yml"), {
    actions: "write",
    contents: "read",
  });

  const job = recordAt(recordAt(workflow, "jobs", "legacy-ios-dispatch.yml"), "dispatch", "legacy-ios-dispatch.yml jobs");
  assert.equal("environment" in job, false);
  const serialized = JSON.stringify(job);
  assert.match(serialized, /Only refs\/heads\/main is trusted/);
  assert.match(serialized, /\.protected/);
  assert.match(serialized, /\^\[0-9a-f\]\{40\}\$/);
  assert.match(serialized, /cc78256c629cd289070c6ad2a3d90a79bc3dcd09/);
  assert.match(serialized, /20572e7313c1e1b83b43462f19c3b9b04872cdfc/);
  assert.match(serialized, /contents\/\.github\/workflows\/\$workflow_file\?ref=\$legacy_sha/);
  assert.match(serialized, /actions\/workflows\/\$WORKFLOW_FILE\/dispatches/);
  assert.match(serialized, /X-GitHub-Api-Version: 2026-03-10/);
  assert.match(serialized, /workflow_run_id/);
  assert.match(serialized, /html_url/);
  assert.match(serialized, /\{ref: \\"main\\"/);
  assert.doesNotMatch(serialized, /secrets\./);
  assert.doesNotMatch(serialized, /load-ios-release-secrets/);
});

test("next CI is visibly distinct from legacy delivery", async () => {
  const workflow = await loadWorkflow("ci-next.yml");
  assert.equal(workflow.name, "Next CI");
  assert.match(stringAt(workflow, "run-name", "ci-next.yml"), /^Next app CI/);
  const verify = recordAt(recordAt(workflow, "jobs", "ci-next.yml"), "verify", "ci-next.yml jobs");
  assert.equal(verify.name, "Verify next Apple workspace");
});
