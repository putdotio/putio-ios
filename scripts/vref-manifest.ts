// Manifest field rules for scripts/vref.ts, split out so they can be tested:
// vref.ts ends in a top-level `await main()`, so importing it runs the build.

/**
 * An ISO 8601 UTC timestamp whose calendar fields survive a round trip.
 * Milliseconds are optional on input and always present on output, so the
 * stored form is canonical and a second run is a no-op.
 *
 * `capturedAt` is written once and preserved after that, so a bad value is
 * permanent — and `updatedAt` is the newest `capturedAt`, so one bad entry drags
 * the gallery with it. `Date.parse` is too lenient to be the gate: it accepts
 * `"0"` and rolls `2024-02-30` forward to March 1st, turning a typo into a
 * plausible date.
 */
const ISO_UTC = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$/u;

export function normalizeCapturedAt(value: string): string | null {
  const match = ISO_UTC.exec(value);
  if (!match) {
    return null;
  }

  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number) as [
    number, number, number, number, number, number,
  ];
  const millisecond = Number((match[7] ?? "0").padEnd(3, "0"));

  // Not Date.UTC, which remaps years 0-99 onto 1900-1999 and would make the
  // round trip below reject a well-formed 0050 timestamp.
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  date.setUTCHours(hour, minute, second, millisecond);

  // Both setters roll out-of-range fields over rather than rejecting them, so
  // comparing back is what catches February 30th and hour 25.
  const survived =
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day &&
    date.getUTCHours() === hour &&
    date.getUTCMinutes() === minute &&
    date.getUTCSeconds() === second;

  return survived ? date.toISOString() : null;
}

/**
 * The value to store for an entry, given whatever the committed manifest had.
 * `fallback` is a thunk so the git lookup only runs for an entry that needs one,
 * and so a test can supply a fixed value instead of shelling out.
 */
export function resolveCapturedAt(
  raw: unknown,
  fallback: () => string,
  describe: (problem: string) => string,
): string {
  const trimmed = typeof raw === "string" ? raw.trim() : "";

  if (trimmed === "") {
    return fallback();
  }

  const normalized = normalizeCapturedAt(trimmed);
  if (normalized === null) {
    throw new Error(describe(JSON.stringify(raw)));
  }

  return normalized;
}
