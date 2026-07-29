// Manifest field rules for scripts/vref.ts, kept in their own module so they can
// be tested: vref.ts ends in a top-level `await main()`, so importing it would run
// the whole build.

/**
 * `capturedAt` is written once and preserved after that, so a bad value is
 * permanent — and because the gallery's `updatedAt` is the newest `capturedAt`,
 * one bad entry drags the whole thing with it.
 *
 * `Date.parse` is far too lenient to be the gate. It accepts `"0"` (a real date
 * in the local zone) and silently rolls `2024-02-30` forward to March 1st, so a
 * typo becomes a plausible-looking date rather than an error.
 *
 * The rule: an ISO 8601 UTC timestamp whose calendar fields survive a round trip.
 * Milliseconds are optional on input and always present on output, so the stored
 * form is canonical and a second run is a no-op.
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
  const date = new Date(Date.UTC(year, month - 1, day, hour, minute, second, millisecond));

  // Date.UTC rolls out-of-range fields over rather than rejecting them, so
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
 *
 * `fallback` is a thunk so the git lookup only happens for an entry that needs
 * one — and so a test can supply a fixed value instead of shelling out.
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
