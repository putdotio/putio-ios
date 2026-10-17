// Summarizes `xcrun xcresulttool get test-results metrics` output into one row
// per test and metric. Kept apart from perf.ts so the arithmetic is tested
// without a simulator.

export interface XcresultMetric {
  displayName: string;
  unitOfMeasurement: string;
  measurements: number[];
}

export interface XcresultTest {
  testIdentifier: string;
  testRuns: { metrics: XcresultMetric[] }[];
}

export interface SummaryRow {
  test: string;
  metric: string;
  unit: string;
  n: number;
  median: number;
  /** Median absolute deviation: a spread one outlier cannot move. */
  mad: number;
  min: number;
  max: number;
}

// XCTest reports durations in seconds and memory in kilobytes; at this scale
// milliseconds and megabytes read without counting digits.
const CONVERSIONS: Record<string, { unit: string; factor: number }> = {
  s: { unit: "ms", factor: 1000 },
  kB: { unit: "MB", factor: 1 / 1024 },
};

export function median(values: number[]): number {
  if (values.length === 0) {
    return Number.NaN;
  }
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[middle - 1]! + sorted[middle]!) / 2 : sorted[middle]!;
}

export function summarize(tests: XcresultTest[]): SummaryRow[] {
  const rows: SummaryRow[] = [];

  for (const test of tests) {
    // "PerformanceUITests/testLaunch()" reads as "testLaunch".
    const name = test.testIdentifier.replace(/^.*\//, "").replace(/\(\)$/, "");

    for (const run of test.testRuns) {
      for (const metric of run.metrics) {
        const conversion = CONVERSIONS[metric.unitOfMeasurement];
        const factor = conversion?.factor ?? 1;
        const values = metric.measurements.map((value) => value * factor);
        const center = median(values);

        rows.push({
          test: name,
          metric: metric.displayName,
          unit: conversion?.unit ?? metric.unitOfMeasurement,
          n: values.length,
          median: center,
          mad: median(values.map((value) => Math.abs(value - center))),
          min: Math.min(...values),
          max: Math.max(...values),
        });
      }
    }
  }

  return rows;
}

/** xcresulttool prints an array of tests; tolerate a single object too. */
export function parseMetrics(json: string): XcresultTest[] {
  const parsed: unknown = JSON.parse(json);
  return (Array.isArray(parsed) ? parsed : [parsed]) as XcresultTest[];
}

export function formatNumber(value: number): string {
  if (!Number.isFinite(value)) {
    return "–";
  }
  const magnitude = Math.abs(value);
  const digits = magnitude >= 100 || Number.isInteger(value) ? 0 : magnitude >= 10 ? 1 : 2;
  return value.toFixed(digits);
}

export function markdownTable(rows: SummaryRow[]): string {
  const lines = [
    "| Test | Metric | Median | MAD | Min–max | n |",
    "| --- | --- | ---: | ---: | ---: | ---: |",
  ];
  for (const row of rows) {
    const unit = row.unit ? ` ${row.unit}` : "";
    lines.push(
      `| ${row.test} | ${row.metric} | ${formatNumber(row.median)}${unit} | ${formatNumber(row.mad)} | ` +
        `${formatNumber(row.min)}–${formatNumber(row.max)} | ${row.n} |`,
    );
  }
  return lines.join("\n");
}
