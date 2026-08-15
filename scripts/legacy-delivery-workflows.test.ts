import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { parse } from "yaml";

type RecordValue = Record<string, unknown>;

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

const loadWorkflow = async (name: string): Promise<RecordValue> =>
  asRecord(
    parse(await readFile(new URL(`../.github/workflows/${name}`, import.meta.url), "utf8")) as unknown,
    name,
  );

test("manual legacy delivery validates before entering the release Environment", async () => {
  for (const [name, deliveryJob] of [
    ["beta.yml", "beta"],
    ["release.yml", "release"],
  ] as const) {
    const workflow = await loadWorkflow(name);
    const jobs = recordAt(workflow, "jobs", name);
    const validate = recordAt(jobs, "validate-ref", `${name}.jobs`);
    const delivery = recordAt(jobs, deliveryJob, `${name}.jobs`);
    const validationInputs = recordAt(validate, "with", `${name}.validate-ref`);

    assert.equal(validate.uses, "./.github/workflows/legacy-delivery-ref.yml");
    assert.equal(
      validationInputs.expected_sha,
      name === "release.yml" ? "${{ inputs.expected_sha || '' }}" : "${{ inputs.expected_sha }}",
    );
    assert.equal("environment" in validate, false);
    assert.equal(delivery.needs, "validate-ref");
    assert.equal(delivery.environment, "release");
    assert.match(JSON.stringify(delivery), /ref.*needs\.validate-ref\.outputs\.sha/);
    assert.doesNotMatch(JSON.stringify(delivery), /ref.*inputs\.expected_sha/);
  }
});

test("the shared guard binds manual dispatch to the protected main event SHA", async () => {
  const workflow = await loadWorkflow("legacy-delivery-ref.yml");
  assert.deepEqual(recordAt(workflow, "permissions", "legacy-delivery-ref.yml"), {
    contents: "read",
  });
  const serialized = JSON.stringify(workflow);
  assert.doesNotMatch(serialized, /environment.*release/);
  assert.doesNotMatch(serialized, /secrets\./);
  assert.doesNotMatch(serialized, /actions\/checkout/);
  assert.match(serialized, /EXPECTED_SHA.*RUN_SHA/);
  assert.match(serialized, /\.protected/);
  assert.match(serialized, /current_sha.*RUN_SHA/);
  assert.match(serialized, /refs\/tags\/\$RELEASE_TAG/);
});

test("beta persists the selected TestFlight groups before distribution", async () => {
  const workflow = await loadWorkflow("beta.yml");
  const jobs = recordAt(workflow, "jobs", "beta.yml");
  const beta = recordAt(jobs, "beta", "beta.yml.jobs");
  const steps = arrayAt(beta, "steps", "beta.yml.jobs.beta").map((step, index) =>
    asRecord(step, `beta.yml.jobs.beta.steps[${index}]`),
  );
  const metadata = steps.find((step) => step.name === "Prepare beta metadata");
  assert.notEqual(metadata, undefined);
  const run = String(metadata?.run);
  const newlineGuard = run.indexOf("PUTIO_BETA_GROUPS\" == *$'\\n'*");
  const envWrite = run.indexOf('echo "PUTIO_BETA_GROUPS=$PUTIO_BETA_GROUPS"');
  assert.notEqual(newlineGuard, -1);
  assert.notEqual(envWrite, -1);
  assert.ok(newlineGuard < envWrite, "group newline validation must precede the GITHUB_ENV write");
  assert.match(run.slice(newlineGuard, envWrite), /exit 1/);
});
