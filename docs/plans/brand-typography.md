# Brand Typography Adoption

Apply the put.io design system's **type scale** across the app — not just the
GT America family, but the design-system roles (sizes, weights, line-heights,
tracking) — while keeping iOS Dynamic Type and the system-font fallback.
Follow-up to the Non-Goal noted in [color-token-migration.md](./color-token-migration.md).

## Source of truth

The canonical scale lives in the design-system project's `system/tokens.json`
(`type` group) and its `Type · Scale` spec. Vendored here as
`Config/TypeScale.json` — a generated mirror of the composed roles; do not
hand-edit values, mirror upstream and re-run the generator.

The design system's ramp is a **web** scale (px, ~15px body, no Dynamic
Type). Rather than port those absolute sizes — too small and non-native for a
touch UI — each role **anchors to an iOS Dynamic Type text style and takes
that style's native point size**, so text matches iOS norms and scales with
the accessibility setting. The design system contributes the families (GT
America for sans, Berkeley Mono for mono), the per-role **weight**, and
tracking; iOS owns the base sizes.

| Role | DS weight / tracking | Anchor (→ native size) |
| --- | --- | --- |
| display | Black 900 / -.025em | largeTitle (~34) |
| h1 | Bold 700 / -.02em | largeTitle (~34) |
| h2 | Bold 700 / -.015em | title1 (~28) |
| h3 | Medium 500 | title2 (~22) |
| h4 | Medium 500 | title3 (~20) |
| body | Regular 400 | body (~17) |
| small | Regular 400 | footnote (~13) |
| label | Medium 500 / +.08em (UPPERCASE) | caption1 (~12) |
| numeric | Berkeley Mono Medium 500 | title3 (~20) |
| code | Berkeley Mono Regular 400 | footnote (~13) |

Native sizes shown are the iOS defaults at the Large content size; they grow
and shrink with the user's accessibility setting, so the table lists the
anchor rather than a fixed point size.

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Approach | Design-system family + weights + tracking on **iOS-native sizes**, Dynamic-Type-scaled. The web px ramp is deliberately not ported — mobile keeps native sizing so text isn't too small and stays enlargeable |
| Dynamic Type | Each role's base size is its anchor text style's native iOS size, then `UIFontMetrics(forTextStyle: anchor).scaledFont(for:)` keeps it responsive to accessibility sizing |
| API | `BrandTypography` (generated from `Config/TypeScale.json`) exposes a role → resolved style: font, tracking, line-height multiple, uppercase flag; system-font fallback when faces absent |
| Label auto-mapping | The `UILabel` appearance hook maps a label's existing Apple text style → the nearest DS role and applies the role font. No per-label IB churn |
| Non-nib text | Button / tab-bar / History / Downloads sites assign explicit DS roles |
| Tracking / line-height | This pass applies family + size + weight + Dynamic Type (the visible bulk of the scale). Tracking and line-height are carried on `BrandTypography.Style` and adopted incrementally at owned attributed-text sites; the global font hook sets the font only |
| Uppercase (`label` role) | Carried on the style, applied only to text explicitly designated `label` — never blanket-applied (would change content casing). The auto hook never resolves to `label` |
| Verify baselines | Unchanged. Verify excludes fonts → every path takes the system fallback → baselines stay on system fonts, zero drift |
| Mono family | Berkeley Mono is the design system's only mono face — it carries both `numeric` and `code`. GT America Mono is not used |

## Apple text style → DS role map (auto hook)

`largeTitle → h1`, `title1 → h2`, `title2 → h3`, `title3/headline → h4`,
`footnote/caption1/caption2 → small`, everything else (`body/callout/
subheadline`) → `body`. The hook never resolves to `label` — its uppercase
treatment must be applied deliberately, not swept across every caption.
Fixed-size labels (no text style) match their current point size on the
brand face.

## Verification

- `make verify` green with **zero baseline drift** (fonts absent → system
  fallback everywhere).
- `make type-scale-verify` drift gate in `verify-fast`.
- Throwaway fonts-bundled record for the DS-scale before/after; committed
  baselines stay on system fonts.
- `BrandFontTests` continues to assert the no-fonts-in-Verify contract; add
  `BrandTypographyTests` for role → fallback parity.

## Non-Goals

- Re-recording committed baselines on brand fonts.
- Applying the `numeric` role at call sites (the role exists; no screen uses it yet).
- Blanket uppercasing; per-role letter-spacing beyond the owned sites above.
