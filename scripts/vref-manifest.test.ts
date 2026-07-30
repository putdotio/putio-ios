// Run with `mise run verify-scripts-tests`. Node's built-in runner strips types
// and executes directly, so there is no test framework and no build step.

import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { normalizeCapturedAt, resolveCapturedAt } from "./vref-manifest.ts";

const FALLBACK = "2020-01-01T00:00:00.000Z";
const fallback = () => FALLBACK;
const describeProblem = (value: string) => `bad capturedAt ${value}`;

describe("normalizeCapturedAt", () => {
  test("accepts the canonical form unchanged", () => {
    assert.equal(normalizeCapturedAt("2026-07-29T09:29:31.000Z"), "2026-07-29T09:29:31.000Z");
  });

  test("fills in absent milliseconds so the stored form is canonical", () => {
    assert.equal(normalizeCapturedAt("2026-07-29T09:29:31Z"), "2026-07-29T09:29:31.000Z");
  });

  test("is idempotent", () => {
    const once = normalizeCapturedAt("2026-07-29T09:29:31Z");
    assert.equal(normalizeCapturedAt(once!), once);
  });

  // Each of these is accepted by Date.parse, which is why it is not the gate.
  test("rejects a date Date.parse would silently roll over", () => {
    assert.equal(new Date("2024-02-30T00:00:00.000Z").toISOString(), "2024-03-01T00:00:00.000Z");
    assert.equal(normalizeCapturedAt("2024-02-30T00:00:00.000Z"), null);
  });

  test("rejects a bare number Date.parse would accept", () => {
    assert.ok(!Number.isNaN(new Date("0").getTime()));
    assert.equal(normalizeCapturedAt("0"), null);
  });

  test("rejects an out-of-range time", () => {
    assert.equal(normalizeCapturedAt("2026-07-29T25:00:00.000Z"), null);
  });

  test("rejects a non-UTC offset rather than guessing what it means", () => {
    assert.equal(normalizeCapturedAt("2026-07-29T12:29:31.000+03:00"), null);
  });

  test("rejects free text and a date with no time", () => {
    assert.equal(normalizeCapturedAt("not a date"), null);
    assert.equal(normalizeCapturedAt("2026-07-29"), null);
  });

  // Date.UTC remaps years 0-99 onto 1900-1999, so building the date that way
  // fails the round trip on a well-formed four-digit year.
  test("accepts a two-digit-looking year without remapping it to the 1900s", () => {
    assert.equal(new Date(Date.UTC(50, 0, 1)).toISOString(), "1950-01-01T00:00:00.000Z");
    assert.equal(normalizeCapturedAt("0050-01-01T00:00:00.000Z"), "0050-01-01T00:00:00.000Z");
    assert.equal(normalizeCapturedAt("0099-12-31T23:59:59.999Z"), "0099-12-31T23:59:59.999Z");
  });
});

describe("resolveCapturedAt", () => {
  test("falls back when the field is absent", () => {
    assert.equal(resolveCapturedAt(undefined, fallback, describeProblem), FALLBACK);
  });

  test("falls back when the field is empty or whitespace", () => {
    assert.equal(resolveCapturedAt("", fallback, describeProblem), FALLBACK);
    assert.equal(resolveCapturedAt("   ", fallback, describeProblem), FALLBACK);
  });

  test("falls back when the field is not a string at all", () => {
    assert.equal(resolveCapturedAt(1_754_000_000, fallback, describeProblem), FALLBACK);
  });

  test("preserves a valid value instead of recomputing it", () => {
    assert.equal(
      resolveCapturedAt("2001-02-03T04:05:06.000Z", fallback, describeProblem),
      "2001-02-03T04:05:06.000Z",
    );
  });

  test("trims a valid value", () => {
    assert.equal(
      resolveCapturedAt("  2001-02-03T04:05:06.000Z  ", fallback, describeProblem),
      "2001-02-03T04:05:06.000Z",
    );
  });

  test("throws on an invalid value rather than falling back to a plausible one", () => {
    assert.throws(
      () => resolveCapturedAt("2024-02-30T00:00:00.000Z", fallback, describeProblem),
      /bad capturedAt "2024-02-30T00:00:00\.000Z"/u,
    );
  });
});
