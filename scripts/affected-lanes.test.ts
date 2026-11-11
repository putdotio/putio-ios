import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { type Lane, lanes, lanesFor, miseLanes } from "./affected-lanes.ts";

const select = (...paths: string[]): Lane[] => lanes.filter((lane) => lanesFor(paths).has(lane));
const apple: Lane[] = ["checks", "build", "ios", "tvos", "proof"];

test("docs, agent skills, and developer-only scripts skip every Apple lane", () => {
  assert.deepEqual(select("AGENTS.md", "scripts/xcode-skills.sh"), ["tooling"]);
  assert.deepEqual(select("docs/session.md", ".agents/skills/verify-putio-apple/SKILL.md"), [
    "tooling",
  ]);
  assert.deepEqual(
    select(".claude/skills/x/SKILL.md", "LICENSE", "skills-lock.json", "scripts/open.sh"),
    ["tooling"],
  );
  assert.deepEqual(
    select("docs/diagram.svg", "Tests/Formal/Session/Session.tla", "scripts/dead-code.sh"),
    [],
  );
});

test("TypeScript tooling runs only the tooling lane", () => {
  assert.deepEqual(select("scripts/string-catalog.ts", "scripts/string-catalog.test.ts"), [
    "tooling",
  ]);
  assert.deepEqual(select("tsconfig.json", "Config/AndroidStrings.json"), ["tooling"]);
  assert.deepEqual(select("scripts/app-store.ts"), ["tooling", "store"]);
  assert.deepEqual(select("scripts/install-asc.sh"), ["store"]);
});

test("each Swift change runs only the platforms that compile it", () => {
  assert.deepEqual(select("Apps/iOS/Sources/Files/FileRow.swift"), [
    "checks",
    "build",
    "ios",
    "proof",
  ]);
  assert.deepEqual(select("Apps/watchOS/Sources/App.swift"), ["checks", "build", "ios", "proof"]);
  assert.deepEqual(select("Apps/tvOS/Sources/App.swift"), ["checks", "build", "tvos"]);
  assert.deepEqual(select("Tests/iOS/Sources/FileRowTests.swift"), ["checks", "ios", "proof"]);
  assert.deepEqual(select("Tests/tvOSUITests/Sources/LaunchTests.swift"), ["checks", "tvos"]);
  assert.deepEqual(select("Tests/ComponentSnapshots/Sources/ComponentGallerySnapshotTests.swift"), [
    "checks",
    "ios",
    "tvos",
    "proof",
  ]);
  assert.deepEqual(select("Tests/ComponentSnapshots/__Snapshots__/ios/gallery.png"), ["ios"]);
  assert.deepEqual(select("Tests/ComponentSnapshots/__Snapshots__/tvos/gallery.png"), ["tvos"]);
  assert.deepEqual(select("Apps/Shared/Sources/Theme.swift"), apple);
  assert.deepEqual(select("Packages/PutioCore/Sources/Session.swift"), apple);
  assert.deepEqual(select("Tools/PutioHarness/Sources/PutioHarness/main.swift"), apple);
  assert.deepEqual(select("Project.swift", ".xcode-version", "Tuist/Package.swift"), apple);
});

test("lane scripts select their own lane", () => {
  assert.deepEqual(select("scripts/build.sh"), ["build"]);
  assert.deepEqual(select("scripts/harness-ci.sh"), ["proof"]);
  assert.deepEqual(select("scripts/test.sh"), ["checks"]);
  assert.deepEqual(select("scripts/harness.sh"), apple);
});

test("CI definitions, dependency pins, and unknown paths select every lane", () => {
  for (const path of [
    ".github/workflows/ci-next.yml",
    ".github/actions/setup-apple/action.yml",
    "scripts/affected-lanes.ts",
    "pnpm-lock.yaml",
    "Config/BrandFonts.json",
    "an/unlisted/path",
    "mise.toml",
  ]) {
    assert.deepEqual(select(path), [...lanes], path);
  }
});

test("mise.toml selects lanes only for tools, settings, and the tasks CI runs", async () => {
  const before = await readFile(new URL("../mise.toml", import.meta.url), "utf8");
  const newTask = `${before}\n[tasks.lint]\ndescription = "Lint"\nrun = "true"\n`;
  assert.deepEqual(miseLanes(before, newTask), []);
  assert.deepEqual(miseLanes(before, before.replace(/^periphery = .*$/m, 'periphery = "9.9.9"')), [
    ...lanes,
  ]);
  assert.deepEqual(
    miseLanes(
      before,
      before.replace('run = "./scripts/verify.sh"', 'run = "./scripts/verify.sh --x"'),
    ),
    [...lanes],
  );
  assert.deepEqual(
    miseLanes(before, before.replace('run = "./scripts/harness-ci.sh"', 'run = "true"')),
    [...lanes],
  );
  assert.deepEqual(
    miseLanes(before, before.replace('run = "./scripts/open.sh"', 'run = "true"')),
    [],
  );
  assert.deepEqual(miseLanes(before, `${before}\n[env]\nFOO = "1"\n`), [...lanes]);
});
