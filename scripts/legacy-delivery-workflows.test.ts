import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
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

const loadYaml = async (path: string): Promise<RecordValue> =>
  asRecord(parse(await readFile(new URL(`../${path}`, import.meta.url), "utf8")) as unknown, path);

test("manual legacy delivery validates before entering the release Environment", async () => {
  for (const [name, deliveryJob] of [
    ["beta.yml", "beta"],
    ["release.yml", "release"],
  ] as const) {
    const workflow = await loadYaml(`.github/workflows/${name}`);
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
  const workflow = await loadYaml(".github/workflows/legacy-delivery-ref.yml");
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
  const workflow = await loadYaml(".github/workflows/beta.yml");
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

const validSentryDsn = "https://synthetickey@o0.ingest.example.invalid/5282170";

// Runs the release preflight with every required secret set to a valid
// synthetic value, then the overrides.
const releasePreflight = async () => {
  const action = await loadYaml(".github/actions/load-ios-release-secrets/action.yml");
  const steps = arrayAt(recordAt(action, "runs", "action.yml"), "steps", "action.yml.runs");
  const preflight = steps
    .map((step, index) => asRecord(step, `action.yml.runs.steps[${index}]`))
    .find((step) => step.name === "Require release environment secrets");
  assert.ok(preflight, "action.yml must have a 'Require release environment secrets' step");
  const run = String(preflight.run);
  const secrets = Object.fromEntries([...run.matchAll(/^\s+([A-Z][A-Z0-9_]*)$/gm)].map(([, name]) => [name, "synthetic"]));
  return (overrides: Record<string, string>) =>
    spawnSync("bash", ["-c", run], {
      encoding: "utf8",
      env: { PATH: process.env.PATH, ...secrets, PUTIO_SENTRY_DSN: validSentryDsn, ...overrides },
    });
};

test("release builds fail without a Sentry DSN for project ios", async () => {
  const preflight = await releasePreflight();
  const status = (dsn: string) => preflight({ PUTIO_SENTRY_DSN: dsn }).status;

  assert.equal(status(validSentryDsn), 0);
  for (const dsn of [
    "",
    "not a dsn",
    "https://synthetickey@o0.ingest.example.invalid/5282171",
    "https://synthetickey@o0.ingest.example.invalid?x=/5282170",
  ]) {
    assert.equal(status(dsn), 1, dsn);
  }
});

test("release builds fail without well-formed Intercom keys", async () => {
  const preflight = await releasePreflight();

  for (const name of ["PUTIO_INTERCOM_API_KEY", "PUTIO_INTERCOM_APP_ID"]) {
    assert.equal(preflight({ [name]: "Synthetic.key_0:a-z" }).status, 0, name);
    for (const value of ["", "null", "canary value", "canary\n", "'canary'", "canary/key"]) {
      const result = preflight({ [name]: value });
      assert.equal(result.status, 1, `${name}=${JSON.stringify(value)}`);
      assert.match(result.stderr, new RegExp(name));
      assert.doesNotMatch(result.stdout + result.stderr, /canary/, "the preflight must not print the value");
    }
  }
});
