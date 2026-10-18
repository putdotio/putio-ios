#!/usr/bin/env node

// Measures the app against the large-account fixture: builds once, runs
// PutioUITests/PerformanceUITests on one simulator, and prints the median and
// spread of every metric the tests report.
//
// The build keeps DEBUG, which the mocked API needs, but compiles with release
// optimization into its own DerivedData, so verify's cache is untouched.
// Without --simulator it creates an ephemeral simulator and deletes it on exit;
// pass one UDID for a whole before/after series so both sides share a device.
//
// Usage:
//   mise run perf
//   mise run perf -- --iterations 5 --only testLaunchToFiles,testSelectAll
//   mise run perf -- --simulator <udid> --label before
//   mise run perf -- --latency-ms 300
//
// Writes build/perf/<label>.xcresult and build/perf/<label>.json.

import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import process from "node:process";

import { markdownTable, parseMetrics, summarize } from "./perf-metrics.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SUITE = "PutioUITests/PerformanceUITests";
const OPTIMIZED = [
  "SWIFT_OPTIMIZATION_LEVEL=-O",
  "SWIFT_COMPILATION_MODE=wholemodule",
  "GCC_OPTIMIZATION_LEVEL=s",
  "ENABLE_TESTABILITY=NO",
];

interface Options {
  iterations: number;
  latencyMs: number;
  simulator?: string;
  only: string[];
  label: string;
}

function parseOptions(): Options {
  const { values } = parseArgs({
    options: {
      iterations: { type: "string", default: "10" },
      "latency-ms": { type: "string", default: "0" },
      simulator: { type: "string" },
      only: { type: "string" },
      label: { type: "string", default: "perf" },
    },
  });

  const iterations = Number(values.iterations);
  const latencyMs = Number(values["latency-ms"]);
  if (!Number.isInteger(iterations) || iterations < 1) {
    fail(`--iterations must be a positive integer; got '${values.iterations}'`);
  }
  if (!Number.isInteger(latencyMs) || latencyMs < 0) {
    fail(`--latency-ms must be a non-negative integer; got '${values["latency-ms"]}'`);
  }
  // The label names files under build/perf, so keep it to one path segment.
  if (!/^[\w.-]+$/.test(values.label)) {
    fail(`--label must be letters, digits, '.', '_' or '-'; got '${values.label}'`);
  }

  return {
    iterations,
    latencyMs,
    simulator: values.simulator,
    only: values.only ? values.only.split(",").map((name) => name.trim()).filter(Boolean) : [],
    label: values.label,
  };
}

function main(): void {
  const options = parseOptions();
  const outputDir = join(ROOT, "build/perf");
  const bundle = join(outputDir, `${options.label}.xcresult`);
  mkdirSync(outputDir, { recursive: true });

  let ephemeral: string | undefined;
  const cleanup = () => {
    if (ephemeral) {
      spawnSync("xcrun", ["simctl", "shutdown", ephemeral], { stdio: "ignore" });
      spawnSync("xcrun", ["simctl", "delete", ephemeral], { stdio: "ignore" });
      ephemeral = undefined;
    }
  };
  // spawnSync blocks, so these run once the interrupted xcodebuild has exited.
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => {
      cleanup();
      process.exit(130);
    });
  }

  try {
    const udid = options.simulator ?? createSimulator();
    if (!options.simulator) {
      ephemeral = udid;
    }

    const context = describeRun(udid, options);
    for (const [key, value] of Object.entries(context)) {
      console.log(`${key}: ${value}`);
    }

    const xcodebuild = [
      "-workspace", "Putio.xcworkspace",
      "-scheme", "PutioE2E",
      "-configuration", "Debug",
      "-xcconfig", "Config/Verify.xcconfig",
      "-destination", `platform=iOS Simulator,id=${udid}`,
      "-derivedDataPath", "build/perf/DerivedData",
      ...OPTIMIZED,
    ];

    const built = spawnSync("xcodebuild", [...xcodebuild, "build-for-testing", "-quiet"], { cwd: ROOT, stdio: "inherit" });
    if (built.status !== 0) {
      fail(`xcodebuild build-for-testing exited ${built.status}`);
    }

    rmSync(bundle, { recursive: true, force: true });
    const tests = options.only.length > 0 ? options.only.map((name) => `${SUITE}/${name}`) : [SUITE];
    const testStatus = spawnSync(
      "xcodebuild",
      [
        ...xcodebuild,
        "test-without-building",
        "-parallel-testing-enabled", "NO",
        ...tests.map((test) => `-only-testing:${test}`),
        "-resultBundlePath", bundle,
        "-quiet",
      ],
      {
        cwd: ROOT,
        stdio: "inherit",
        // xcodebuild hands TEST_RUNNER_-prefixed variables to the test runner
        // without the prefix.
        env: {
          ...process.env,
          TEST_RUNNER_PUTIO_PERF: "1",
          TEST_RUNNER_PUTIO_PERF_ITERATIONS: String(options.iterations),
          TEST_RUNNER_PUTIO_PERF_LATENCY_MS: String(options.latencyMs),
        },
      },
    ).status;

    const metrics = execFileSync(
      "xcrun",
      ["xcresulttool", "get", "test-results", "metrics", "--path", bundle, "--compact"],
      { cwd: ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
    );
    const rows = summarize(parseMetrics(metrics));

    console.log("");
    console.log(markdownTable(rows));
    writeFileSync(join(outputDir, `${options.label}.json`), `${JSON.stringify({ context, rows }, null, 2)}\n`);
    console.log(`\nWrote ${bundle} and build/perf/${options.label}.json`);

    if (testStatus !== 0) {
      fail(`xcodebuild test-without-building exited ${testStatus}; the table covers the tests that reported`);
    }
  } finally {
    cleanup();
  }
}

function createSimulator(): string {
  const output = execFileSync(join(ROOT, "scripts/simctl-ephemeral-device.sh"), ["--label", "perf"], {
    cwd: ROOT,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  });
  const udid = output.trim().split("\n").pop() ?? "";
  if (!/^[0-9A-F-]{36}$/i.test(udid)) {
    fail(`simctl-ephemeral-device.sh printed no device id; got '${output.trim()}'`);
  }
  return udid;
}

// What a number needs beside it to be compared later: the same commit, device,
// runtime, toolchain, and settings.
function describeRun(udid: string, options: Options): Record<string, string> {
  const sha = execFileSync("git", ["rev-parse", "--short=12", "HEAD"], { cwd: ROOT, encoding: "utf8" }).trim();
  const dirty = execFileSync("git", ["status", "--porcelain"], { cwd: ROOT, encoding: "utf8" }).trim() !== "";
  const xcode = execFileSync("xcodebuild", ["-version"], { encoding: "utf8" }).trim().split("\n").join(" ");

  const devices = JSON.parse(execFileSync("xcrun", ["simctl", "list", "-j", "devices"], { encoding: "utf8" })) as {
    devices: Record<string, { udid: string; name: string }[]>;
  };
  let simulator = udid;
  for (const [runtime, list] of Object.entries(devices.devices)) {
    const device = list.find((candidate) => candidate.udid === udid);
    if (device) {
      // com.apple.CoreSimulator.SimRuntime.iOS-26-4 reads as iOS 26.4.
      const version = runtime.replace(/^.*\.SimRuntime\./, "").replace(/^(\w+?)-(\d+)-(\d+)$/, "$1 $2.$3");
      simulator = `${device.name} (${version}) ${udid}`;
    }
  }

  return {
    commit: dirty ? `${sha} (uncommitted changes)` : sha,
    simulator,
    xcode,
    iterations: String(options.iterations),
    latency: `${options.latencyMs} ms`,
    build: `Debug + ${OPTIMIZED.join(" ")}`,
  };
}

class PerfError extends Error {}

// Throws rather than exiting, so main's finally still deletes the simulator.
function fail(message: string): never {
  throw new PerfError(message);
}

try {
  main();
} catch (error) {
  if (!(error instanceof PerfError)) {
    throw error;
  }
  console.error(`perf: ${error.message}`);
  process.exitCode = 1;
}
