import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { parse } from "yaml";

import { dynamicBinary, latestVersion } from "./cast-sdk-release.ts";

const SCRIPT = fileURLToPath(new URL("./cast-sdk-release.ts", import.meta.url));
const DYNAMIC_URL = "https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-4.8.6_dynamic.zip";
const DYNAMIC_CHECKSUM = "55f6c21291a1315c68063f07e7d76225564bff70f2fd38caad135c71d66eb310";
const STATIC_CHECKSUM = "e1fe7fd6f2bf4b58e830d378fafc435d159bd755f7ee20fd3033aa1ce313cd6e";
const TAGS = [[{ name: "4.8.6" }, { name: "4.8.4" }]];

const upstreamPackage = (dynamic: string) => `  targets: [
    .binaryTarget(
      name: "GoogleCastStaticBinary",
      url: "https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-4.8.6_static.zip",
      checksum: "${STATIC_CHECKSUM}"
    ),
    .target(
      name: "GoogleCastDynamic",
      dependencies: [
        .target(name: "GoogleCastDynamicBinary"),
        .product(name: "GTMSessionFetcher", package: "gtm-session-fetcher")
      ],
      path: ".",
      sources: ["GoogleCastDynamic.swift"]
    ),
${dynamic}  ]
`;

const dynamicTarget = (url: string, checksum: string) => `    .binaryTarget(
      name: "GoogleCastDynamicBinary",
      url: "${url}",
      checksum: "${checksum}"
    ),
`;

const UPSTREAM_486 = upstreamPackage(dynamicTarget(DYNAMIC_URL, DYNAMIC_CHECKSUM));

const fakeGh = `#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"
case "$*" in
  "api --method "*) printf '%s\\t%s\\n' "$*" "$(cat)" >> "$GH_WRITES"; echo '{"html_url":"https://github.com/putdotio/putio-ios/issues/41"}' ;;
  "api --paginate --slurp repos/googlecast/google-cast-ios-sdk/tags?"*) printf '%s\\n' "$FAKE_TAGS" ;;
  "api -H Accept: application/vnd.github.raw repos/googlecast/google-cast-ios-sdk/contents/Package.swift?ref="*) printf '%s' "$FAKE_UPSTREAM" ;;
  "api --paginate --slurp repos/putdotio/putio-ios/issues?state=open&"*) printf '%s\\n' "$FAKE_ISSUES" ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
`;

type Write = Readonly<{ args: string; payload: { title: string; body: string } }>;
type Scenario = Readonly<{ pinned?: string; tags?: unknown; upstream?: string; issues?: unknown }>;

const run = async (t: test.TestContext, scenario: Scenario) => {
  const dir = await mkdtemp(join(tmpdir(), "cast-sdk-release-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await writeFile(join(dir, "gh"), fakeGh);
  await chmod(join(dir, "gh"), 0o755);
  await writeFile(join(dir, "calls"), "");
  await writeFile(join(dir, "writes"), "");
  const result = spawnSync(process.execPath, [SCRIPT], {
    encoding: "utf8",
    env: {
      PATH: `${dir}:${process.env.PATH}`,
      GH_CALLS: join(dir, "calls"),
      GH_WRITES: join(dir, "writes"),
      GITHUB_REPOSITORY: "putdotio/putio-ios",
      FAKE_TAGS: JSON.stringify(scenario.tags ?? TAGS),
      FAKE_UPSTREAM: scenario.upstream ?? UPSTREAM_486,
      FAKE_ISSUES: JSON.stringify(scenario.issues ?? [[]]),
      ...(scenario.pinned === undefined ? {} : { PINNED_VERSION: scenario.pinned }),
    },
  });
  const lines = async (name: string) => (await readFile(join(dir, name), "utf8")).split("\n").filter(Boolean);
  const writes = (await lines("writes")).map((line): Write => {
    const [args = "", payload = ""] = line.split("\t");
    return { args, payload: JSON.parse(payload) as Write["payload"] };
  });
  return { status: result.status, stdout: result.stdout, stderr: result.stderr, calls: await lines("calls"), writes };
};

test("the latest upstream tag is the highest MAJOR.MINOR.PATCH one", () => {
  assert.equal(latestVersion(["4.8.6", "4.10.0", "4.9.12", "v5", "5.0.0-beta1", "4.8", "05.0.0"]), "4.10.0");
  assert.equal(latestVersion(["latest", "4.8"]), undefined);
});

test("a newer upstream tag opens one issue naming its version, dynamic zip, and checksum", async (t) => {
  const result = await run(t, { pinned: "4.8.4" });

  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.calls.some((call) => call.endsWith("contents/Package.swift?ref=4.8.6")), "reads the 4.8.6 Package.swift");
  assert.equal(result.writes.length, 1);
  const [created] = result.writes;
  assert.equal(created?.args, "api --method POST repos/putdotio/putio-ios/issues --input -");
  assert.match(created?.payload.title ?? "", /\b4\.8\.6\b/);
  assert.ok(created?.payload.body.includes(`url: "${DYNAMIC_URL}"`), "names the dynamic zip URL");
  assert.ok(created?.payload.body.includes(`checksum: "${DYNAMIC_CHECKSUM}"`), "names the dynamic zip checksum");
  assert.ok(!created?.payload.body.includes(STATIC_CHECKSUM), "skips the static zip");
});

test("a second run updates the open issue in place and opens no new one", async (t) => {
  const first = await run(t, { pinned: "4.8.4" });
  const opened = first.writes[0]?.payload;
  assert.ok(opened, first.stderr);
  const issue = { number: 12, user: { login: "github-actions[bot]" }, ...opened };
  const pullRequest = { ...issue, number: 13, pull_request: {} };

  const second = await run(t, { pinned: "4.8.4", issues: [[pullRequest], [issue]] });

  assert.equal(second.status, 0, second.stderr);
  assert.deepEqual(second.writes, [{ args: "api --method PATCH repos/putdotio/putio-ios/issues/12 --input -", payload: opened }]);
});

test("an alert copied into someone else's issue is not reused", async (t) => {
  const first = await run(t, { pinned: "4.8.4" });
  const opened = first.writes[0]?.payload;
  assert.ok(opened, first.stderr);

  const result = await run(t, { pinned: "4.8.4", issues: [[{ number: 5, user: { login: "someone" }, ...opened }]] });

  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.writes.map((write) => write.args), ["api --method POST repos/putdotio/putio-ios/issues --input -"]);
});

test("a pin at or past the latest tag stays quiet", async (t) => {
  const latest = await run(t, { pinned: "4.8.6" });
  assert.equal(latest.status, 0, latest.stderr);
  assert.deepEqual(latest.writes, []);
  assert.ok(!latest.calls.some((call) => call.includes("putio-ios/issues")), "never looks for an issue");

  const fromPackage = await run(t, { tags: [[{ name: "0.0.1" }]] });
  assert.equal(fromPackage.status, 0, fromPackage.stderr);
  assert.deepEqual(fromPackage.writes, []);
});

test("an upstream dynamic binary without a dl.google.com zip and sha256 checksum opens nothing", async (t) => {
  for (const [name, target] of [
    ["missing", ""],
    ["short checksum", dynamicTarget(DYNAMIC_URL, DYNAMIC_CHECKSUM.slice(1))],
    ["other host", dynamicTarget(DYNAMIC_URL.replace("dl.google.com", "dl.example.com"), DYNAMIC_CHECKSUM)],
    ["plain http", dynamicTarget(DYNAMIC_URL.replace("https:", "http:"), DYNAMIC_CHECKSUM)],
  ] as const) {
    assert.equal(dynamicBinary(upstreamPackage(target)), undefined, name);
  }

  const result = await run(t, { pinned: "4.8.4", upstream: upstreamPackage("") });
  assert.equal(result.status, 1);
  assert.deepEqual(result.writes, []);
});

test("the workflow runs weekly and on dispatch with an optional pin, and may only read code and write issues", async () => {
  const workflow = parse(await readFile(new URL("../.github/workflows/cast-sdk-release.yml", import.meta.url), "utf8")) as {
    on: { schedule: { cron: string }[]; workflow_dispatch: { inputs: { pinned_version: { required: boolean } } } };
    permissions: unknown;
    jobs: Record<string, { "runs-on": string; "timeout-minutes": number; permissions?: unknown; steps: { uses?: string; run?: string; env?: Record<string, string> }[] }>;
  };

  assert.equal(workflow.on.schedule.length, 1);
  assert.match(workflow.on.schedule[0]?.cron ?? "", /^\d+ \d+ \* \* [0-6]$/);
  assert.equal(workflow.on.workflow_dispatch.inputs.pinned_version.required, false);
  assert.deepEqual(workflow.permissions, { contents: "read", issues: "write" });

  for (const [name, job] of Object.entries(workflow.jobs)) {
    assert.equal(job["runs-on"], "ubuntu-latest", name);
    assert.ok(job["timeout-minutes"] > 0, name);
    assert.equal(job.permissions, undefined, name);
    for (const step of job.steps) if (step.uses) assert.match(step.uses, /@[0-9a-f]{40}$/, step.uses);
  }
  const step = Object.values(workflow.jobs).flatMap((job) => job.steps).find((candidate) => candidate.run?.includes("scripts/cast-sdk-release.ts"));
  assert.deepEqual(step?.env, { GH_TOKEN: "${{ github.token }}", PINNED_VERSION: "${{ inputs.pinned_version }}" });

  const lanes = spawnSync("sh", [fileURLToPath(new URL("./ci-affected.sh", import.meta.url))], { encoding: "utf8", input: ".github/workflows/cast-sdk-release.yml\n" });
  assert.match(lanes.stdout, /^tooling=true$/m);
});
