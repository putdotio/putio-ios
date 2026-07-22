# Brand Typography Adoption

Extend the licensed GT America faces beyond navigation titles (shipped in
the fonts stack) to the rest of the app's text, while preserving Dynamic
Type and the system-font fallback. Follows up on the Non-Goal noted in
[color-token-migration.md](./color-token-migration.md).

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Mechanism for nib labels | A `UILabel` `awakeFromNib` appearance extension (mirrors the existing `UITableViewCell+Appearance` / `UITextField+Appearance` convention) reads each label's Dynamic Type text style and remaps to GT America scaled for that style |
| Dynamic Type | Preserved: `UIFontMetrics(forTextStyle:).scaledFont(for:)` over a GT America base sized at the style's default; `adjustsFontForContentSizeCategory` stays on |
| Weight mapping | Derived from the label's existing `.weight` trait, then snapped to the nearest bundled face (Regular / Medium / Bold / Black) by `BrandFont` |
| Fallback | Every call site uses a `…IfAvailable` accessor with the *original* font expression as the `?? fallback`, so a build without fonts renders byte-identically |
| Verify baselines | Unchanged. Verify builds never bundle fonts, so all paths take the system fallback and snapshot baselines stay on system fonts |
| Non-nib text | The custom `Button`, tab-bar item titles, and the few programmatic `.font` sites (History/Downloads) are branded explicitly at their existing style points |
| Fixed-size labels | Labels without a Dynamic Type text style (a UIButton's default title label, or a fixed-point storyboard label such as the audio player's "UP NEXT") match their current point size on the brand face — same helper, no `UIFontMetrics` scaling |

## Surface (from the audit)

- ~51 storyboard/xib labels, dominated by Body / Callout / Caption1 text
  styles → handled wholesale by the `UILabel` extension.
- Custom `Button` (`applyVariantStyle`) → title font branded.
- Tab-bar item titles → branded via `UITabBarItem.appearance()`.
- Programmatic font sites: `HistoryViewController` (section header 14pt
  semibold), `DownloadsViewController` (headline / title1 / body).

## Verification

- `make verify` must stay green with **zero baseline drift** (fonts absent
  → system fallback everywhere).
- A throwaway fonts-bundled record (flip `PUTIO_BUNDLE_BRAND_FONTS`, record,
  restore) provides the visual before/after for the PR; baselines are not
  re-recorded with fonts.
- `BrandFontTests` continues to assert the no-fonts-in-Verify contract.
- Manual light + dark sweep in the simulator with fonts synced.

## Non-Goals

- Re-recording committed baselines on brand fonts (breaks the determinism
  contract).
- Custom per-screen type scales or letter-spacing tuning; this maps the
  existing Dynamic Type styles onto the brand face 1:1.
