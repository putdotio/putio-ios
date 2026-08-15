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
  assert.deepEqual(recordAt(dispatch, "with", "beta.yml dispatch"), {
    operation: "beta",
    legacy_ref: "${{ inputs.legacy_ref }}",
    changelog: "${{ inputs.changelog }}",
    groups: "${{ inputs.groups }}",
    processing_timeout_minutes: "${{ inputs.processing_timeout_minutes }}",
  });
  assert.equal("environment" in dispatch, false);
  assert.equal("secrets" in dispatch, false);
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

  assert.deepEqual(recordAt(workflow, "permissions", "release.yml"), {
    actions: "write",
    contents: "read",
  });
  const dispatch = recordAt(recordAt(workflow, "jobs", "release.yml"), "dispatch", "release.yml jobs");
  assert.equal(dispatch.uses, "./.github/workflows/legacy-ios-dispatch.yml");
  assert.deepEqual(recordAt(dispatch, "with", "release.yml dispatch"), {
    operation: "release",
    legacy_ref: "${{ inputs.legacy_ref }}",
    version: "${{ inputs.version }}",
  });
  assert.equal("environment" in dispatch, false);
  assert.equal("secrets" in dispatch, false);
});

test("the relay fails closed before dispatching the reviewed main workflows", async () => {
  const workflow = await loadWorkflow("legacy-ios-dispatch.yml");
  assert.equal(workflow.name, "Legacy iOS 3.x dispatch contract");
  const on = recordAt(workflow, "on", "legacy-ios-dispatch.yml");
  assert.deepEqual(Object.keys(on), ["workflow_call"]);
  const callInputs = recordAt(recordAt(on, "workflow_call", "legacy-ios-dispatch.yml.on"), "inputs", "legacy-ios-dispatch.yml.on.workflow_call");
  assert.deepEqual(Object.keys(callInputs), [
    "operation",
    "legacy_ref",
    "changelog",
    "groups",
    "processing_timeout_minutes",
    "version",
  ]);
  assert.deepEqual(recordAt(workflow, "permissions", "legacy-ios-dispatch.yml"), {
    actions: "write",
    contents: "read",
  });

  const job = recordAt(recordAt(workflow, "jobs", "legacy-ios-dispatch.yml"), "dispatch", "legacy-ios-dispatch.yml jobs");
  assert.equal("environment" in job, false);
  const steps = arrayAt(job, "steps", "legacy-ios-dispatch.yml dispatch").map((step, index) =>
    asRecord(step, `legacy-ios-dispatch.yml steps[${index}]`),
  );
  assert.deepEqual(
    steps.map((step) => step.name),
    [
      "Resolve the protected legacy ref",
      "Prepare the bounded legacy dispatch payload",
      "Dispatch the existing workflow on protected main",
      "Record the legacy handoff",
    ],
  );
  for (const step of steps) assert.equal("uses" in step, false, `${String(step.name)} must not invoke an action`);

  const resolveRun = stringAt(steps[0] ?? {}, "run", "resolve step");
  assert.match(resolveRun, /if \[ "\$LEGACY_REF" != "refs\/heads\/main" \]; then[\s\S]*exit 1/);
  assert.match(resolveRun, /if \[ "\$protected" != "true" \]; then[\s\S]*exit 1/);
  assert.match(resolveRun, /if \[ "\$workflow_blob" != "\$expected_workflow_blob" \]; then[\s\S]*exit 1/);

  const payloadRun = stringAt(steps[1] ?? {}, "run", "payload step");
  assert.equal(payloadRun.match(/return_run_details: true/g)?.length, 2);
  assert.equal(payloadRun.match(/expected_sha: \$expected_sha/g)?.length, 2);
  assert.match(payloadRun, /groups: \$groups/);

  const dispatchRun = stringAt(steps[2] ?? {}, "run", "dispatch step");
  const recheckIndex = dispatchRun.indexOf('if [ "$current_legacy_sha" != "$RESOLVED_LEGACY_SHA" ]');
  const postIndex = dispatchRun.indexOf("--method POST");
  assert.notEqual(recheckIndex, -1);
  assert.ok(recheckIndex < postIndex, "protected-main SHA recheck must precede the POST");
  assert.match(dispatchRun.slice(recheckIndex, postIndex), /exit 1/);
  assert.match(dispatchRun, /X-GitHub-Api-Version: 2026-03-10/);
  assert.match(dispatchRun, /workflow_run_id/);
  assert.match(dispatchRun, /html_url/);

  const serialized = JSON.stringify(job);
  assert.match(serialized, /c72211e00159fe4d2a010fe1d0816b9de6a7d707/);
  assert.match(serialized, /759b0a86119fb5059d2655f6c5491ff9ed7361ef/);
  assert.match(serialized, /actions\/workflows\/\$WORKFLOW_FILE\/dispatches/);
  assert.doesNotMatch(serialized, /secrets\./);
  assert.doesNotMatch(serialized, /secrets: inherit/);
  assert.doesNotMatch(serialized, /load-ios-release-secrets/);
  assert.doesNotMatch(serialized, /actions\/checkout/);
});

test("next CI is visibly distinct from legacy delivery", async () => {
  const workflow = await loadWorkflow("ci-next.yml");
  assert.equal(workflow.name, "Next CI");
  assert.match(stringAt(workflow, "run-name", "ci-next.yml"), /^Next app CI/);
  const verify = recordAt(recordAt(workflow, "jobs", "ci-next.yml"), "verify", "ci-next.yml jobs");
  assert.equal(verify.name, "Verify next Apple workspace");
});
