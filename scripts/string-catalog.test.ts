import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { normalizeFormat, parseAndroidStrings } from "./string-catalog.ts";

const iosCatalog = "Apps/iOS/Sources/Localizable.xcstrings";
const coreCatalog = "Packages/PutioCore/Sources/PutioCore/Resources/Localizable.xcstrings";

type Entry = { comment?: string; value?: string; plural?: Record<string, string> };

const catalog = (entries: Record<string, Entry>): string =>
  JSON.stringify({
    sourceLanguage: "en",
    version: "1.0",
    strings: Object.fromEntries(
      Object.entries(entries).map(([key, entry]) => [
        key,
        {
          comment: entry.comment,
          localizations: {
            en: entry.plural
              ? {
                  variations: {
                    plural: Object.fromEntries(
                      Object.entries(entry.plural).map(([category, value]) => [category, { stringUnit: { value } }]),
                    ),
                  },
                }
              : { stringUnit: { value: entry.value ?? key } },
          },
        },
      ]),
    ),
  });

const baseIOS: Record<string, Entry> = {
  "Try again": { comment: "android: mobile_action_retry" },
  "Could not cast": { comment: "android: mobile_cast_failed | differs: iOS board wording" },
  "Loading on %@": { comment: "ios-only: no Android string for the iOS Chromecast controls" },
  "Deleted %lld items.": {
    comment: "ios-only: no Android string for the iOS trash screen",
    plural: { one: "Deleted %lld item.", other: "Deleted %lld items." },
  },
};

const baseSwift = `import SwiftUI

struct CastView: View {
  let device: String
  let count: Int
  var body: some View {
    Button("Try again") {}
      .accessibilityIdentifier("cast.retry")
    Text(String(localized: "Loading on \\(device)"))
    Text(String(localized: "Deleted \\(count) items."))
  }
  var title: String { String(localized: "Could not cast") }
}
`;

const baseCore = `import SwiftUI

struct Badge: View {
  var body: some View { Text("Watched", bundle: .module) }
}
`;

const run = async (changes: { ios?: Record<string, Entry>; swift?: string; core?: string; coreCatalog?: Record<string, Entry> }) => {
  const root = await mkdtemp(join(tmpdir(), "putio-string-catalog-"));
  try {
    const write = async (path: string, text: string) => {
      await mkdir(dirname(join(root, path)), { recursive: true });
      await writeFile(join(root, path), text);
    };
    await mkdir(join(root, "scripts"));
    await copyFile(new URL("./string-catalog.ts", import.meta.url), join(root, "scripts/string-catalog.ts"));
    await write(
      "Config/AndroidStrings.json",
      JSON.stringify({
        repository: "putdotio/putio-android",
        commit: "0".repeat(40),
        files: [],
        strings: {
          mobile_action_retry: "Try again",
          mobile_cast_failed: "Can’t play this on %1$s.",
          mobile_files_watched: "Watched",
        },
      }),
    );
    await write(iosCatalog, catalog(changes.ios ?? baseIOS));
    await write(coreCatalog, catalog(changes.coreCatalog ?? { Watched: { comment: "android: mobile_files_watched" } }));
    await write("Apps/iOS/Sources/Cast/CastView.swift", changes.swift ?? baseSwift);
    await write("Packages/PutioCore/Sources/PutioCore/Components/Badge.swift", changes.core ?? baseCore);
    return spawnSync(process.execPath, [join(root, "scripts/string-catalog.ts"), "--check"], { encoding: "utf8" });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
};

test("a fully recorded catalog passes and lists ios-only strings", async () => {
  const result = await run({});
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /\[iOS\] Loading on %@ — no Android string for the iOS Chromecast controls/);
  assert.match(result.stdout, /5 catalog keys: 3 mapped to Android \(1 intended differences\), 2 ios-only/);
});

test("keys that differ only in their format specifiers are both used", async () => {
  const result = await run({
    ios: {
      ...baseIOS,
      "%lld of %lld": { comment: "ios-only: a counter" },
      "%@ of %@": { comment: "ios-only: a position" },
    },
    swift: baseSwift.replace(
      "  var title",
      '  var counter: String { String(localized: "\\(count) of \\(count)") }\n  var position: String { String(localized: "\\(device) of \\(device)") }\n  var title',
    ),
  });
  assert.equal(result.status, 0, result.stderr);
});

test("check fails on each broken rule", async (t) => {
  const cases: [string, Parameters<typeof run>[0], RegExp][] = [
    ["key without a record", { ios: { ...baseIOS, "Try again": {} } }, /"Try again" needs a comment/],
    [
      "unmarked Android difference",
      { ios: { ...baseIOS, "Could not cast": { comment: "android: mobile_cast_failed" } } },
      /"Could not cast" differs from Android mobile_cast_failed/,
    ],
    [
      "stale difference mark",
      { ios: { ...baseIOS, "Try again": { comment: "android: mobile_action_retry | differs: old" } } },
      /"Try again" matches mobile_action_retry; drop "\| differs"/,
    ],
    [
      "unknown Android key",
      { ios: { ...baseIOS, "Try again": { comment: "android: mobile_missing" } } },
      /records Android key mobile_missing/,
    ],
    [
      "value that drifts from its key",
      { ios: { ...baseIOS, "Try again": { comment: "android: mobile_action_retry", value: "Retry" } } },
      /"Try again" English value differs from its key/,
    ],
    [
      "unused catalog key",
      { ios: { ...baseIOS, Gone: { comment: "ios-only: no Android string for a removed screen" } } },
      /"Gone" is not used/,
    ],
    [
      "literal missing from the catalog",
      { swift: baseSwift.replace("{}\n", '{}\n    Text("Brand new copy")\n') },
      /CastView.swift:\d+: "Brand new copy" is not in Apps\/iOS\/Sources\/Localizable.xcstrings/,
    ],
    [
      "unlocalized String literal",
      { swift: baseSwift.replace('String(localized: "Could not cast")', '"Could not cast"') },
      /user-facing literal "Could not cast" is not localized/,
    ],
    [
      "interpolated String literal",
      { swift: baseSwift.replace("  var title", '  var moved: String { "\\(device) to \\(device)" }\n  var title') },
      /user-facing literal "\\\(…\) to \\\(…\)" is not localized/,
    ],
    [
      "nil-coalesced fallback",
      { swift: baseSwift.replace('Text(String(localized: "Loading on \\(device)"))', 'Text(Optional(device) ?? "Loading on device")') },
      /"Loading on device" is not localized/,
    ],
    [
      "code comment on a localized string",
      { swift: baseSwift.replace('String(localized: "Could not cast")', 'String(localized: "Could not cast", comment: "Cast error")') },
      /CastView.swift:\d+: move the comment into the catalog record/,
    ],
    ["PutioCore lookup without its bundle", { core: baseCore.replace(", bundle: .module", "") }, /"Watched" must look up in PutioCore with bundle: .module/],
    [
      "count ternary over words",
      { swift: baseSwift.replace("  var title", '  var noun: String { count == 1 ? "item" : "items" }\n  var title') },
      /CastView.swift: pluralize with a catalog plural variation/,
    ],
  ];
  for (const [name, change, problem] of cases) {
    await t.test(name, async () => {
      const result = await run(change);
      assert.equal(result.status, 1, `${name} should fail`);
      assert.match(result.stderr, problem);
    });
  }
});

test("Android strings parse escapes, entities and plurals", () => {
  const strings = parseAndroidStrings(`<resources>
    <!-- <string name="commented">No</string> -->
    <string name="apostrophe">Don\\'t \\"quote\\" &amp; wait…</string>
    <string name="newline">One\\nTwo</string>
    <string name="cdata"><![CDATA[<b>Bold</b>]]></string>
    <plurals name="items"><item quantity="one">%1$d item</item><item quantity="other">%1$d items</item></plurals>
  </resources>`);
  assert.deepEqual(strings, {
    apostrophe: 'Don\'t "quote" & wait…',
    newline: "One\nTwo",
    cdata: "<b>Bold</b>",
    items: { plurals: { one: "%1$d item", other: "%1$d items" } },
  });
});

test("format specifiers compare across platforms", () => {
  assert.equal(normalizeFormat("%1$s of %2$s used"), normalizeFormat("%@ of %@ used"));
  assert.equal(normalizeFormat("Moved %1$d items"), normalizeFormat("Moved %lld items"));
  assert.equal(normalizeFormat("%1$d%%"), "{1}%");
  assert.notEqual(normalizeFormat("%2$s %1$s"), normalizeFormat("%@ %@"));
});
