// Model-checks the session lifecycle in Tests/Formal/Session/PutioSession.tla
// with a pinned TLC, then reports drift between the model and the code it
// covers. See .agents/skills/verify-session-lifecycle/SKILL.md.
//
//   node scripts/formal-session.ts [--variant <name>] [--excuse-known-finding]
import { execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs, promisify } from "node:util";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const modelDirectory = join(root, "Tests/Formal/Session");
const skill = join(root, ".agents/skills/verify-session-lifecycle/SKILL.md");
const workDirectory = join(root, "build/formal");

const tlc = {
  version: "1.7.4",
  url: "https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar",
  sha256: "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88",
};
const jar = join(workDirectory, `tla2tools-${tlc.version}.jar`);

const bounds = { MaxGen: 10, MaxGrants: 3 };
const properties = ["NoOrphanGrant", "SignedInIsSaved"] as const;
const variants = ["shipped", "noBootstrapGenerationGuard", "dropPendingSignOutToken"] as const;

// Model actions in the code's words, for counterexamples.
const steps: Readonly<Record<string, string>> = {
  RestoreStart: "restore() reads the keychain",
  ValidateDone: "restore() gets the validateToken answer",
  BootstrapDone: "bootstrap() gets the account answer",
  Discard: "discardUnrestoredCredential() (Sign in again)",
  BeginSignIn: "beginSignIn() opens the web sign-in",
  CancelOrFailSignIn: "cancelSignIn() or failSignIn() ends the web sign-in",
  FailBeforeSignIn: "failSignIn() after beginSignIn() threw",
  CompleteSignIn: "completeSignIn(callbackURL:) gets a grant and calls storeSignInToken()",
  DeviceStart: "signInWithDeviceCode() asks for a code",
  CodeDone: "runDeviceCodeSignIn() gets the activation code",
  ApprovalDone: "runDeviceCodeSignIn() gets the approval and calls storeSignInToken()",
  RevokeNewDone: "storeSignInToken() gets the best-effort logout answer",
  SignOutStart: "signOut() clears the keychain and calls logout",
  LogoutDone: "signOut() gets the logout answer",
  ServerRevokes: "the user revokes a grant on put.io",
  AuthenticatedRequestRejected: "a request is rejected and expireSession() runs",
  AccountDestroyed: "destroyAccount() succeeds and endDestroyedSession() runs",
  Relaunch: "the app quits and relaunches",
};

const { values } = parseArgs({
  options: {
    variant: { type: "string", default: "shipped" },
    "excuse-known-finding": { type: "boolean", default: false },
  },
});
const variant = values.variant ?? "shipped";
const excuseKnownFinding = values["excuse-known-finding"] === true;
if (!(variants as readonly string[]).includes(variant)) {
  throw new Error(`--variant must be one of: ${variants.join(", ")}`);
}

const digest = (bytes: Uint8Array): string => createHash("sha256").update(bytes).digest("hex");

const ensureJar = async (): Promise<void> => {
  try {
    if (digest(await readFile(jar)) === tlc.sha256) return;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  const response = await fetch(tlc.url);
  if (!response.ok) throw new Error(`${tlc.url} returned ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (digest(bytes) !== tlc.sha256) throw new Error(`tla2tools.jar ${tlc.version} failed its SHA-256 check`);
  await mkdir(workDirectory, { recursive: true });
  await writeFile(`${jar}.partial`, bytes);
  await rename(`${jar}.partial`, jar);
};

type Outcome = { property: string; passed: boolean; report: string };

const runTLC = async (property: string): Promise<Outcome> => {
  const name = `${property}-${variant}${excuseKnownFinding ? "-excused" : ""}`;
  const config = join(workDirectory, `${name}.cfg`);
  await writeFile(
    config,
    [
      "CONSTANTS",
      ...Object.entries(bounds).map(([name, value]) => `  ${name} = ${value}`),
      `  Variant = "${variant}"`,
      `  KnownFindingExcused = ${excuseKnownFinding ? "TRUE" : "FALSE"}`,
      "SPECIFICATION Spec",
      "INVARIANTS TypeOK " + property,
      "",
    ].join("\n"),
  );
  const states = join(workDirectory, "states", name);
  await rm(states, { recursive: true, force: true });
  const output = await new Promise<string>((done, fail) => {
    const child = spawn(
      "java",
      // One worker keeps breadth-first order, so a counterexample is a shortest one.
      ["-XX:+UseParallelGC", "-cp", jar, "tlc2.TLC", "-workers", "1", "-deadlock",
        "-metadir", states, "-config", config, "PutioSession.tla"],
      { cwd: modelDirectory },
    );
    let text = "";
    child.stdout.on("data", (chunk) => (text += chunk));
    child.stderr.on("data", (chunk) => (text += chunk));
    child.on("error", fail);
    child.on("close", () => done(text));
  });
  if (output.includes("Model checking completed. No error has been found.")) {
    const count = /(\d+) distinct states found/.exec(output)?.[1] ?? "?";
    return { property, passed: true, report: `${property}: holds (${count} distinct states)` };
  }
  if (!output.includes(`Invariant ${property} is violated`)) {
    throw new Error(`TLC did not finish checking ${property}:\n${output}`);
  }
  return { property, passed: false, report: `${property}: VIOLATED\n${counterexample(output)}` };
};

// TLC prints every state in full; keep each step's action and what changed.
const counterexample = (output: string): string => {
  const lines: string[] = [];
  let previous = new Map<string, string>();
  for (const block of output.split(/\nState \d+: /).slice(1)) {
    const [header, ...body] = block.split("\n");
    const action = /^<(\w+) line/.exec(header)?.[1] ?? "Init";
    const current = new Map<string, string>();
    let name = "";
    for (const line of body) {
      const match = /^\/\\ (\w+) = (.*)$/.exec(line);
      if (match) {
        name = match[1];
        current.set(name, match[2]);
      } else if (name && line.startsWith(" ")) {
        current.set(name, `${current.get(name)} ${line.trim()}`);
      } else if (line.trim() === "" || !line.startsWith(" ")) {
        name = "";
      }
    }
    if (action !== "Init") {
      const changed = [...current].filter(([key, value]) => previous.get(key) !== value && key !== "launched");
      const description = steps[action] ?? action;
      lines.push(`  ${lines.length + 1}. ${description}: ${changed.map(([k, v]) => `${k}=${v}`).join(", ")}`);
    }
    previous = current;
  }
  return lines.join("\n");
};

// The model describes the covered code at the skill's sync commit.
const drift = async (): Promise<string[]> => {
  const text = await readFile(skill, "utf8");
  const sync = /^Sync commit: `([0-9a-f]{7,40})`/m.exec(text)?.[1];
  const coverage = text.split(/^## /m).find((section) => section.startsWith("Coverage"));
  const files = [...(coverage ?? "").matchAll(/^- `([^`]+)`/gm)].map((match) => match[1]);
  if (!sync || files.length === 0) throw new Error(`${skill} lacks its sync commit or coverage list`);
  const { stdout } = await promisify(execFile)("git", ["diff", "--name-only", sync, "--", ...files], { cwd: root });
  return stdout.split("\n").filter(Boolean);
};

await ensureJar();
console.log(
  `TLC ${tlc.version}, variant ${variant}${excuseKnownFinding ? ", known finding excused" : ""}, ` +
    `bounds ${JSON.stringify(bounds)}`,
);
const outcomes: Outcome[] = [];
for (const property of properties) {
  const outcome = await runTLC(property);
  console.log(outcome.report);
  outcomes.push(outcome);
}
const changed = await drift();
if (changed.length > 0) {
  console.log(
    `Covered code changed since the sync commit:\n${changed.map((file) => `  ${file}`).join("\n")}\n` +
      "Check the model against it, then move the sync commit in the skill.",
  );
}
if (changed.length > 0 || outcomes.some((outcome) => !outcome.passed)) process.exitCode = 1;
