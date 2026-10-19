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

test("manual delivery validates before entering the release Environment", async () => {
  for (const [name, deliveryJob] of [
    ["beta.yml", "beta"],
    ["release.yml", "release"],
  ] as const) {
    const workflow = await loadYaml(`.github/workflows/${name}`);
    const jobs = recordAt(workflow, "jobs", name);
    const validate = recordAt(jobs, "validate-ref", `${name}.jobs`);
    const delivery = recordAt(jobs, deliveryJob, `${name}.jobs`);
    const validationInputs = recordAt(validate, "with", `${name}.validate-ref`);

    assert.equal(validate.uses, "./.github/workflows/delivery-ref.yml");
    assert.equal(validationInputs.expected_sha, "${{ inputs.expected_sha }}");
    assert.equal("environment" in validate, false);
    assert.equal(delivery.needs, "validate-ref");
    assert.equal(delivery.environment, "release");
    assert.match(JSON.stringify(delivery), /ref.*needs\.validate-ref\.outputs\.sha/);
    assert.doesNotMatch(JSON.stringify(delivery), /ref.*inputs\.expected_sha/);
  }
});

test("the shared guard binds manual dispatch to the protected main event SHA", async () => {
  const workflow = await loadYaml(".github/workflows/delivery-ref.yml");
  assert.deepEqual(recordAt(workflow, "permissions", "delivery-ref.yml"), {
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

test("every workflow that runs asc turns its telemetry off first", async () => {
  for (const name of ["beta.yml", "release.yml", "screenshots.yml", "submit.yml", "ci.yml"]) {
    const workflow = await loadYaml(`.github/workflows/${name}`);
    const serialized = JSON.stringify(workflow);
    assert.match(serialized, /install-asc\.sh/, `${name} installs the pinned asc`);
    assert.doesNotMatch(serialized, /brew install/, `${name} must not install asc from Homebrew`);
    assert.doesNotMatch(serialized, /asc web /, `${name} must not use asc web sessions`);
    const env = name === "ci.yml"
      ? recordAt(recordAt(recordAt(workflow, "jobs", name), "verify-tooling", name), "env", name)
      : recordAt(workflow, "env", name);
    assert.equal(env.ASC_TELEMETRY_DISABLED, "1", `${name} sets ASC_TELEMETRY_DISABLED`);
  }
});

test("submission runs from a validated SHA in the release Environment only", async () => {
  const workflow = await loadYaml(".github/workflows/submit.yml");
  const jobs = recordAt(workflow, "jobs", "submit.yml");
  assert.deepEqual(Object.keys(jobs), ["validate-ref", "submit"]);
  const submit = recordAt(jobs, "submit", "submit.yml.jobs");
  assert.equal(submit.needs, "validate-ref");
  assert.equal(submit.environment, "release");
  assert.match(JSON.stringify(submit), /ref.*needs\.validate-ref\.outputs\.sha/);
});

test("release tags only after the upload, as putio-ci with nothing else", async () => {
  const workflow = await loadYaml(".github/workflows/release.yml");
  assert.deepEqual(Object.keys(recordAt(workflow, "on", "release.yml")), ["workflow_dispatch"]);
  const tag = recordAt(recordAt(workflow, "jobs", "release.yml"), "tag", "release.yml.jobs");
  assert.deepEqual(tag.needs, ["validate-ref", "release"]);
  assert.equal(tag.environment, "release");
  assert.equal("permissions" in tag, false, "the tag needs the App token, not a broader GITHUB_TOKEN");
  const steps = arrayAt(tag, "steps", "release.yml.jobs.tag").map((step, index) => asRecord(step, `tag.steps[${index}]`));
  const mint = steps[0] ?? {};
  assert.match(String(mint.uses), /^actions\/create-github-app-token@[0-9a-f]{40}$/);
  const raw = await readFile(new URL("../.github/workflows/release.yml", import.meta.url), "utf8");
  assert.match(raw, /create-github-app-token@[0-9a-f]{40} # v\d+\.\d+\.\d+/, "pin carries its version comment");
  assert.deepEqual(recordAt(mint, "with", "tag.steps[0]"), {
    "client-id": "${{ vars.PUTIO_CI_APP_CLIENT_ID }}",
    "private-key": "${{ secrets.PUTIO_CI_APP_PRIVATE_KEY }}",
    owner: "${{ github.repository_owner }}",
    repositories: "${{ github.event.repository.name }}",
    "permission-contents": "write",
  });
  const serialized = JSON.stringify(tag);
  assert.deepEqual([...new Set(serialized.match(/secrets\.[A-Z_]+/g))], ["secrets.PUTIO_CI_APP_PRIVATE_KEY"]);
  assert.doesNotMatch(serialized, /actions\/checkout/);
  assert.match(JSON.stringify(steps[1]), /GH_TOKEN.*steps\.token\.outputs\.token/);
});

test("asc output piped to the summary still fails the step", async () => {
  for (const name of ["beta.yml", "release.yml", "submit.yml", "screenshots.yml"]) {
    const workflow = await loadYaml(`.github/workflows/${name}`);
    assert.deepEqual(recordAt(workflow, "defaults", name), { run: { shell: "bash" } }, `${name} runs bash with pipefail`);
  }
  // GitHub runs `shell: bash` as `bash -eo pipefail`; its implicit shell drops pipefail.
  const pipe = (flags: string[]) => spawnSync("bash", [...flags, "-c", "false | tee /dev/null"]).status;
  assert.equal(pipe(["-e"]), 0);
  assert.equal(pipe(["-eo", "pipefail"]), 1);
});

test("workflows that change one App Store version queue behind each other", async () => {
  for (const [name, input] of [
    ["release.yml", "version"],
    ["submit.yml", "version"],
    ["screenshots.yml", "app_version"],
  ] as const) {
    const concurrency = recordAt(await loadYaml(`.github/workflows/${name}`), "concurrency", name);
    assert.equal(concurrency.group, `app-store-\${{ inputs.${input} }}`, `${name} must share the per-version group`);
    assert.equal(concurrency["cancel-in-progress"], false, `${name} must not cancel a running delivery`);
  }

  // A key built from "v3.0.0" would not queue behind one built from "3.0.0".
  const screenshots = await loadYaml(".github/workflows/screenshots.yml");
  const job = recordAt(recordAt(screenshots, "jobs", "screenshots.yml"), "screenshots", "screenshots.yml.jobs");
  const first = asRecord(arrayAt(job, "steps", "screenshots.yml.jobs.screenshots")[0], "screenshots first step");
  for (const [version, ok] of [["3.0.0", true], ["v3.0.0", false], ["3.0", false]] as const) {
    const run = spawnSync("bash", ["-e", "-c", String(first.run)], { env: { ...process.env, APP_VERSION: version } });
    assert.equal(run.status === 0, ok, `screenshots must ${ok ? "accept" : "reject"} ${version} before any other step`);
  }
});

test("beta keeps notifying external testers", async () => {
  const raw = await readFile(new URL("../.github/workflows/beta.yml", import.meta.url), "utf8");
  assert.match(raw, /asc publish testflight[^\n]*(\\\n[^\n]*)*--notify/);
});

test("submit checks committed notes and validates the build it submits", async () => {
  const workflow = await loadYaml(".github/workflows/submit.yml");
  const submit = recordAt(recordAt(workflow, "jobs", "submit.yml"), "submit", "submit.yml.jobs");
  const runs = arrayAt(submit, "steps", "submit").map((step) => String(asRecord(step, "step").run ?? ""));
  const at = (pattern: RegExp) => runs.findIndex((run) => pattern.test(run));
  const check = at(/app-store\.ts check --version/);
  const attach = at(/asc versions attach-build[\s\S]*--build-number "\$BUILD_NUMBER"/);
  const validate = at(/app-store\.ts validate --version "\$VERSION" --strict/);
  const send = at(/asc review submit[\s\S]*--build-number "\$BUILD_NUMBER"/);
  assert.ok(check >= 0 && check < attach && attach < validate && validate < send, "check, attach, validate, submit in order");
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
