import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { pkcs7Payload, RubyTime, rubyInteger } from "./check-signing-profile.ts";

test("profile dates parse and print as Ruby's Time.iso8601 does", () => {
  const cases: [string, string][] = [
    ["2001-01-01T00:00:00Z", "2001-01-01 00:00:00 UTC"],
    ["2001-01-01T00:00:00.500+03:00", "2001-01-01 00:00:00.5 +0300"],
    ["2001-01-01T00:00:00.123456789123Z", "2001-01-01 00:00:00 123456789123/1000000000000 UTC"],
    ["2001-02-31T00:00:00Z", "2001-03-03 00:00:00 UTC"],
    ["2001-01-01T24:00:00Z", "2001-01-02 00:00:00 UTC"],
    ["2001-01-01T00:00:00+00:00", "2001-01-01 00:00:00 +0000"],
    ["2001-01-01T00:00:00-00:00", "2001-01-01 00:00:00 UTC"],
    ["2001-01-01T00:00:00+05:99", "2001-01-01 00:00:00 +0639"],
    [" 2001-01-01t00:00:00+0530 ", "2001-01-01 00:00:00 +0530"],
    ["-0001-01-01T00:00:00Z", "-0001-01-01 00:00:00 UTC"],
  ];
  for (const [text, inspected] of cases) assert.equal(RubyTime.iso8601(text).inspect(), inspected, text);

  const refused: [string, string][] = [
    ["2001-01-01", 'invalid xmlschema format: "2001-01-01"'],
    ["2001-13-01T00:00:00Z", "mon out of range"],
    ["2001-01-00T00:00:00Z", "mday out of range"],
    ["2001-01-32T00:00:00Z", "argument out of range"],
    ["2001-01-01T25:00:00Z", "hour out of range"],
    ["2001-01-01T24:01:00Z", "min out of range"],
    ["2001-01-01T24:00:01Z", "sec out of range"],
    ["2001-01-01T00:00:00+24:00", "utc_offset out of range"],
  ];
  for (const [text, message] of refused) assert.throws(() => RubyTime.iso8601(text), { message }, text);
});

test("plist integers parse as Ruby's Integer() does", () => {
  const cases: [string, bigint][] = [["0x1f", 31n], ["0X1F", 31n], ["010", 8n], ["0b11", 3n], ["0o17", 15n], ["1_000", 1000n], ["0_1", 1n], ["-5", -5n], ["+5", 5n]];
  for (const [text, value] of cases) assert.equal(rubyInteger(text), value, text);
  for (const text of ["_1", "1__0", "08", "1e3", ""]) assert.throws(() => rubyInteger(text), { message: `invalid value for Integer(): ${JSON.stringify(text)}` }, text);
});

test("a streamed, indefinite-length signature yields its payload", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "putio-pkcs7-test-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const made = spawnSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=signer",
    "-keyout", join(dir, "signer.key"), "-out", join(dir, "signer.pem")], { encoding: "utf8" });
  assert.equal(made.status, 0, made.stderr);
  const payload = "<plist><dict/></plist>\n".repeat(200);
  await writeFile(join(dir, "payload"), payload);
  const signed = spawnSync("openssl", ["cms", "-sign", "-nodetach", "-binary", "-stream", "-outform", "DER", "-in", join(dir, "payload"),
    "-signer", join(dir, "signer.pem"), "-inkey", join(dir, "signer.key")]);
  assert.equal(signed.status, 0, String(signed.stderr));
  assert.equal(signed.stdout[1], 0x80, "the signature uses indefinite lengths");
  assert.equal(pkcs7Payload(signed.stdout).toString("utf8"), payload);
});
