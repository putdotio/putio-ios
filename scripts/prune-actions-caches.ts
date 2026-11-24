import { fileURLToPath } from "node:url";

export type CacheEntry = Readonly<{ id: number; key: string; ref: string; createdAt: string }>;

type Family = Readonly<{ pattern: RegExp; keep: number }>;

// A runner image rollout can serve two iOS runtimes for days, so two templates stay.
export const families: readonly Family[] = [
  { pattern: /^(macOS-xcode-cas-(?:ios|tvos|build))-/, keep: 1 },
  { pattern: /^(macOS-simulator-template)-/, keep: 2 },
  { pattern: /^(macOS-tuist-build)-/, keep: 1 },
  { pattern: /^(macOS-swiftpm)-/, keep: 1 },
  { pattern: /^(macOS-pnpm)-/, keep: 1 },
  { pattern: /^(macOS-[A-Z0-9]+-putio-harness)-/, keep: 1 },
  { pattern: /^(mise-v1-[a-z]+-[a-z0-9]+)-/, keep: 1 },
];

export const staleCaches = (entries: readonly CacheEntry[], ref: string): CacheEntry[] => {
  const groups = new Map<string, { keep: number; entries: CacheEntry[] }>();
  for (const entry of entries) {
    if (entry.ref !== ref) continue;
    for (const family of families) {
      const name = family.pattern.exec(entry.key)?.[1];
      if (name === undefined) continue;
      const group = groups.get(name) ?? { keep: family.keep, entries: [] };
      group.entries.push(entry);
      groups.set(name, group);
      break;
    }
  }
  return [...groups.values()].flatMap(({ keep, entries: members }) =>
    members.toSorted((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt)).slice(keep),
  );
};

const parseEntry = (value: unknown): CacheEntry => {
  if (typeof value !== "object" || value === null) throw new Error("cache entry must be an object");
  const { id, key, ref, created_at: createdAt } = value as Record<string, unknown>;
  if (typeof id !== "number" || typeof key !== "string" || typeof ref !== "string" || typeof createdAt !== "string") {
    throw new Error(`malformed cache entry: ${JSON.stringify(value)}`);
  }
  if (Number.isNaN(Date.parse(createdAt))) throw new Error(`cache ${id} has an invalid created_at`);
  return { id, key, ref, createdAt };
};

const requiredEnv = (name: string): string => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
};

const main = async (): Promise<void> => {
  const repository = requiredEnv("GITHUB_REPOSITORY");
  const ref = requiredEnv("PRUNE_REF");
  const headers = {
    accept: "application/vnd.github+json",
    authorization: `Bearer ${requiredEnv("GITHUB_TOKEN")}`,
    "x-github-api-version": "2022-11-28",
  };
  const api = `https://api.github.com/repos/${repository}/actions/caches`;
  const entries: CacheEntry[] = [];
  for (let page = 1; ; page += 1) {
    const response = await fetch(`${api}?ref=${encodeURIComponent(ref)}&per_page=100&page=${page}`, { headers });
    if (!response.ok) throw new Error(`listing caches failed: ${response.status} ${await response.text()}`);
    const body = (await response.json()) as { actions_caches?: unknown };
    if (!Array.isArray(body.actions_caches)) throw new Error("cache listing has no actions_caches array");
    entries.push(...body.actions_caches.map(parseEntry));
    if (body.actions_caches.length < 100) break;
  }
  const failures: string[] = [];
  for (const entry of staleCaches(entries, ref)) {
    const response = await fetch(`${api}/${entry.id}`, { method: "DELETE", headers });
    if (response.ok || response.status === 404) {
      console.log(`deleted ${entry.key}`);
    } else {
      failures.push(`${entry.key}: ${response.status} ${await response.text()}`);
    }
  }
  if (failures.length > 0) throw new Error(`could not delete:\n${failures.join("\n")}`);
};

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main();
}
