import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { join, relative } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const sources = ["Apps", "Packages/PutioCore/Sources"];

const swiftFiles = async (directory: string): Promise<string[]> => {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(
    entries.map((entry) => {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) return swiftFiles(path);
      return Promise.resolve(entry.name.endsWith(".swift") ? [path] : []);
    }),
  );
  return nested.flat();
};

const callArguments = (text: string, open: number): string => {
  let depth = 0;
  for (let index = open; index < text.length; index += 1) {
    if (text[index] === "(") depth += 1;
    if (text[index] === ")") depth -= 1;
    if (depth === 0) return text.slice(open + 1, index);
  }
  return text.slice(open + 1);
};

// PutioSDK's default file details query asks for stream_url, mp4_stream_url
// and mp4_size, so the API signs URLs on every lookup. Each call names the
// query it needs instead.
test("every SDK file lookup names its details query", async () => {
  const unnamed: string[] = [];
  for (const source of sources) {
    for (const file of await swiftFiles(join(root, source))) {
      const text = await readFile(file, "utf8");
      for (const match of text.matchAll(/\bsdk\.getFile\(/g)) {
        const open = match.index + match[0].length - 1;
        if (/\bquery:/.test(callArguments(text, open))) continue;
        const line = text.slice(0, match.index).split("\n").length;
        unnamed.push(`${relative(root, file)}:${line}`);
      }
    }
  }
  assert.deepEqual(unnamed, []);
});
