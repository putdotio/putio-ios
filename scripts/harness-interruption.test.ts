import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

// Only the child receives these stand-ins; no real Simulator command can run.
const fixture = `
const fs = require("node:fs");
const path = require("node:path");
const root = process.env.INTERRUPTION_FIXTURE;
const devices = path.join(root, "devices");
const args = process.argv.slice(2);
const log = (event) => fs.appendFileSync(path.join(root, "events"), event + "\\n");
const add = (udid, name) => fs.writeFileSync(path.join(devices, udid), JSON.stringify({ udid, name }));
if (path.basename(process.argv[1]) === "swift") {
  const index = args.indexOf("--run-id");
  const runID = index < 0 ? "unrequested" : args[index + 1];
  const owned = "owned-" + runID;
  for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143]]) {
    process.on(signal, () => {
      log(signal);
      if (process.env.LEAVE_OWNED !== "1") fs.rmSync(path.join(devices, owned), { force: true });
      process.exit(code);
    });
  }
  add("aaa-unrelated", "another-agent-device");
  setTimeout(() => add(owned, "putio-harness-ios-" + runID + "-deadbeef"), 150);
  setTimeout(() => process.exit(99), 5000);
} else if (args[0] === "simctl" && args[1] === "list") {
  console.log(JSON.stringify({ devices: { runtime: fs.readdirSync(devices).map(file => JSON.parse(fs.readFileSync(path.join(devices, file), "utf8"))) } }));
} else if (args[0] === "simctl" && ["shutdown", "delete"].includes(args[1])) {
  log(args[1] + " " + args[2]);
  if (args[1] === "delete") fs.rmSync(path.join(devices, args[2]), { force: true });
} else {
  throw new Error("unexpected fixture invocation");
}
`;

test("interruption checks preserve unrelated devices and clean only their own on failure", async (t) => {
  for (const leaveOwned of [false, true]) {
    await t.test(leaveOwned ? "failed cleanup" : "both signals", async () => {
      const directory = await mkdtemp(path.join(tmpdir(), "putio-interruption-"));
      try {
        const bin = path.join(directory, "bin");
        const devices = path.join(directory, "devices");
        await mkdir(bin);
        await mkdir(devices);
        await writeFile(path.join(devices, "preexisting"), JSON.stringify({ udid: "preexisting", name: "existing-device" }));
        const executable = path.join(bin, "fixture.cjs");
        await writeFile(executable, `#!${process.execPath}\n${fixture}`, { mode: 0o755 });
        await symlink(executable, path.join(bin, "swift"));
        await symlink(executable, path.join(bin, "xcrun"));
        const result = await new Promise<{ code: number | null; output: string }>((resolve, reject) => {
          const child = spawn("bash", [new URL("./test-harness-interruption.sh", import.meta.url).pathname], {
            env: {
              ...process.env,
              PATH: `${bin}:${process.env.PATH ?? ""}`,
              INTERRUPTION_FIXTURE: directory,
              LEAVE_OWNED: leaveOwned ? "1" : "0",
            },
            timeout: 15000,
          });
          let output = "";
          child.stdout.on("data", (data) => { output += data; });
          child.stderr.on("data", (data) => { output += data; });
          child.on("error", reject);
          child.on("close", (code) => resolve({ code, output }));
        });
        assert.equal(result.code, leaveOwned ? 1 : 0, result.output);
        assert.deepEqual((await readdir(devices)).sort(), ["aaa-unrelated", "preexisting"]);
        const events = await readFile(path.join(directory, "events"), "utf8");
        assert.match(events, /SIGINT/);
        if (leaveOwned) {
          assert.match(result.output, /owned Simulator .* remains after INT/);
          assert.match(events, /delete owned-/);
        } else {
          assert.match(events, /SIGTERM/);
          assert.doesNotMatch(events, /delete /);
        }
      } finally {
        await rm(directory, { recursive: true, force: true });
      }
    });
  }
});
