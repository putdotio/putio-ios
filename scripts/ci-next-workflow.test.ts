import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import picomatch from "picomatch";
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

  assert.deepEqual(arrayAt(pullRequest, "types", "ci-next.yml.on.pull_request"), [
    "opened",
    "synchronize",
    "reopened",
    "closed",
  ]);

  const push = recordAt(triggers, "push", "ci-next.yml.on");
  assert.deepEqual(arrayAt(push, "branches", "ci-next.yml.on.push"), ["next"]);

  const jobs = recordAt(workflow, "jobs", "ci-next.yml");
  assert.equal(
    recordAt(jobs, "changes", "ci-next.yml.jobs").if,
    "github.event.action != 'closed'",
    "a closed pull request only cancels its stale run",
  );
});

type GitHubContext = Readonly<{
  event_name: string;
  ref: string;
  run_id: string;
  event: { pull_request?: { number: number } };
}>;

// Covers the expression subset concurrency settings use (`github.*`, quoted
// strings, `==`, `!=`, `&&`, `||`, `!`). Property access is null-safe, as in
// GitHub expressions.
const evaluate = (value: unknown, github: GitHubContext): unknown => {
  if (typeof value !== "string") return value;
  const run = (expression: string): unknown => {
    assert.match(expression, /^[\w.\s'=!&|]+$/, `unsupported expression: ${expression}`);
    const nullSafe = expression.replace(/(\w)\.(?=\w)/g, "$1?.");
    return new Function("github", `return (${nullSafe});`)(github) as unknown;
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
  const push = (runId: string) =>
    settle({ event_name: "push", ref: "refs/heads/next", run_id: runId, event: {} });
  const pullRequest = (runId: string, ref = "refs/pull/7/merge") =>
    settle({ event_name: "pull_request", ref, run_id: runId, event: { pull_request: { number: 7 } } });

  // A shared group would let a later push cancel, or replace while queued, an
  // earlier one, so that merged commit would get no result of its own.
  assert.notEqual(push("1").group, push("2").group);
  assert.notEqual(push("1").group, pullRequest("2").group);
  assert.equal(pullRequest("3").group, pullRequest("4").group);
  assert.equal(pullRequest("4").cancelInProgress, true);
  assert.equal(pullRequest("5", "refs/heads/next").group, pullRequest("3").group, "merging cancels the open run");
});

const laneFilters = async (): Promise<Map<string, readonly string[]>> => {
  const workflow = await loadWorkflow("ci-next.yml");
  const changes = recordAt(recordAt(workflow, "jobs", "ci-next.yml"), "changes", "jobs");
  const step = arrayAt(changes, "steps", "changes")
    .map((value) => asRecord(value, "changes step"))
    .find((value) => value.id === "filter");
  assert.ok(step, "changes must have a filter step");
  const options = recordAt(step, "with", "filter");
  assert.equal(options["predicate-quantifier"], "every");
  const filters = asRecord(parse(stringAt(options, "filters", "filter")) as unknown, "filters");
  return new Map(
    Object.entries(filters).map(([name, patterns]) => [name, [patterns].flat(Infinity) as string[]]),
  );
};

const selectedLanes = (filters: Map<string, readonly string[]>, paths: readonly string[]): string[] =>
  ["checks", "build", "ios", "tvos"].filter((lane) =>
    paths.some((path) => (filters.get(lane) ?? []).every((pattern) => picomatch(pattern, { dot: true })(path))),
  );

test("pull requests start only the macOS lanes their paths reach", async () => {
  const filters = await laneFilters();
  const lanes = (...paths: string[]) => selectedLanes(filters, paths);
  const every = ["checks", "build", "ios", "tvos"];

  assert.deepEqual(lanes("AGENTS.md", "mise-tasks.toml", "scripts/xcode-skills.sh"), []);
  assert.deepEqual(lanes("docs/session.md", ".agents/skills/verify-putio-apple/SKILL.md", "LICENSE"), []);
  assert.deepEqual(lanes("scripts/string-catalog.ts", "scripts/string-catalog.test.ts", "tsconfig.json"), []);
  assert.deepEqual(lanes("Apps/iOS/Sources/Files/FileRow.swift"), ["checks", "build", "ios"]);
  assert.deepEqual(lanes("Apps/tvOS/Sources/App.swift"), ["checks", "build", "tvos"]);
  assert.deepEqual(lanes("Tests/iOS/Sources/FileRowTests.swift"), ["checks", "ios"]);
  const gallery = "Tests/ComponentSnapshots/Sources/__Snapshots__/ComponentGallerySnapshotTests";
  assert.deepEqual(lanes(`${gallery}/testFilesPage.ios.png`), ["ios"]);
  assert.deepEqual(lanes(`${gallery}/testFilesPage.tvos.png`), ["tvos"]);
  assert.deepEqual(lanes("Tests/iOS/Sources/Files/__Snapshots__/FilesBrowserRenderingTests/root.1.png"), ["ios"]);
  assert.deepEqual(lanes("Tests/tvOS/Sources/__Snapshots__/TVPlaybackTests/overlay.1.png"), ["tvos"]);
  assert.deepEqual(lanes("Tests/HarnessMedia/audio/a.m4a"), ["build", "ios", "tvos"]);
  assert.deepEqual(lanes("scripts/build.sh"), ["build"]);
  for (const path of [
    "Packages/PutioCore/Sources/Session.swift",
    "Tools/PutioHarness/Sources/PutioHarness/main.swift",
    "mise.toml",
    "mise.lock",
    "package.json",
    "scripts/sync-brand-fonts.ts",
    ".github/workflows/ci-next.yml",
    ".github/actions/setup-apple/action.yml",
    "an/unlisted/path",
  ]) {
    assert.deepEqual(lanes(path), every, path);
  }
});
