import assert from "node:assert/strict";
import test from "node:test";

import { type CacheEntry, staleCaches } from "./prune-actions-caches.ts";

const next = "refs/heads/next";
let id = 0;
const entry = (key: string, createdAt: string, ref = next): CacheEntry => ({ id: ++id, key, ref, createdAt });

test("only the newest entry per key family on next survives, and two simulator templates", () => {
  const entries = [
    entry("macOS-xcode-cas-ios-2026-48-f63a972406f01148cae6b048e58976da81bd20b6", "2026-11-24T15:47:00Z"),
    entry("macOS-xcode-cas-ios-2026-48-1f86bd362b2aee8ab6dccd1c75858fb3aaaaaaaa", "2026-11-24T15:22:00Z"),
    entry("macOS-xcode-cas-ios-2026-47-ec564b2c7d182e77066276a64bb33f57aaaaaaaa", "2026-11-17T13:39:00Z"),
    entry("macOS-xcode-cas-tvos-2026-48-f63a972406f01148cae6b048e58976da81bd20b6", "2026-11-24T15:32:00Z"),
    entry("macOS-xcode-cas-build-2026-48-f63a972406f01148cae6b048e58976da81bd20b6", "2026-11-24T15:33:00Z"),
    entry("macOS-xcode-cas-build-2026-48-9cc6904bdabae9b6cff124a89ebafe75a33bfbe8", "2026-11-24T14:00:00Z"),
    entry("macOS-simulator-template-v2-xcode-27B52-ios-24B91016s-coresimulator-1174.21", "2026-11-24T14:19:00Z"),
    entry("macOS-simulator-template-v2-xcode-27B52-ios-24B8117-coresimulator-1174.21", "2026-11-24T02:48:00Z"),
    entry("macOS-simulator-template-v2-xcode-27B40-ios-24B7000-coresimulator-1174.20", "2026-11-20T02:48:00Z"),
    entry("macOS-tuist-build-6667f29967e30190140393ccfa61803ba1f7897312688891b8b319be90d21a", "2026-11-24T12:52:00Z"),
    entry("macOS-tuist-build-f7462d8d8cbb365b155fa3b1e13a75654f9b06345ac81dd02112be161a91c0", "2026-11-23T12:52:00Z"),
    entry("macOS-swiftpm-42536abc03d1fbc7a7336253ffa0a2490de42855832ca3ca9e0a886cebf794b9", "2026-11-24T12:04:00Z"),
    entry("macOS-ARM64-putio-harness-9d858e4391392814dd853b1971ad5145d2da0935e0cf458bcf0091e25429a031", "2026-11-23T00:44:00Z"),
    entry("mise-v1-macos-arm64-macos27-2026.11.12-p692-fb3173308b090d00fd54171cf8925642d1dd", "2026-11-24T02:17:00Z"),
    entry("mise-v1-linux-x64-ubuntu26-2026.11.12-66a319b3d9321e42482fec944d88148c6f7cfa9768", "2026-11-24T12:32:00Z"),
    entry("mise-v1-linux-arm64-ubuntu24-arm64-2026.11.12-2da428783882de", "2026-11-24T13:54:00Z"),
    entry("macOS-tuist-build-6667f29967e30190140393ccfa61803ba1f7897312688891b8b319be90d21a", "2026-11-24T13:00:00Z", "refs/pull/1314/merge"),
    entry("macOS-tuist-manifests-55db4e615a5935c60edb2fbad2d986e3e32f9fc1841", "2026-11-20T14:38:00Z"),
  ];

  assert.deepEqual(
    staleCaches(entries, next)
      .map((stale) => stale.key)
      .sort(),
    [
      "macOS-simulator-template-v2-xcode-27B40-ios-24B7000-coresimulator-1174.20",
      "macOS-tuist-build-f7462d8d8cbb365b155fa3b1e13a75654f9b06345ac81dd02112be161a91c0",
      "macOS-xcode-cas-build-2026-48-9cc6904bdabae9b6cff124a89ebafe75a33bfbe8",
      "macOS-xcode-cas-ios-2026-47-ec564b2c7d182e77066276a64bb33f57aaaaaaaa",
      "macOS-xcode-cas-ios-2026-48-1f86bd362b2aee8ab6dccd1c75858fb3aaaaaaaa",
    ],
  );
});
