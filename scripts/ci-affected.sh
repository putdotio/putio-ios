#!/bin/sh
# Reads changed paths (one per line, stdin) and prints which CI lanes the diff
# can affect, as `app=<bool>` / `tooling=<bool>` lines for $GITHUB_OUTPUT.
#
# An unrecognized path counts as app-affecting. A false positive costs one
# macOS verify run; a false negative merges a break, so anything new defaults
# to running the expensive lane.

set -eu

app=false
tooling=false

while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
    # Prose, and the workflows that ship or publish rather than test.
    *.md | LICENSE | docs/* | .github/ISSUE_TEMPLATE/*) ;;
    .github/workflows/beta.yml | .github/workflows/release.yml) ;;
    .github/workflows/screenshots.yml | .github/workflows/e2e-simulator.yml) ;;
    # Gallery data. Nothing in CI reads it.
    .vref/*) ;;
    # The control plane. These decide what every lane runs — mise.toml pins Node
    # and Ruby and defines the tasks, and the other two are this gate itself —
    # so a change to one has to be exercised by both lanes rather than only the
    # one the default below would pick.
    mise.toml | .github/workflows/ci.yml | scripts/ci-affected.sh)
        app=true
        tooling=true
        ;;
    # Visual baselines are asserted by the app lane *and* are the input the
    # committed marketing images are rendered from, so verify-store-images has to
    # see them too. Without this a baseline-only change — exactly the #69 case
    # that check exists for — would run the app lane and skip the check.
    PutioTests/__Snapshots__/* | PutioUITests/__Snapshots__/* | PutioUITests/__Captures__/*)
        app=true
        tooling=true
        ;;
    # Node tooling. The app target builds with no Node involvement, so these
    # reach the type-check lane only — until one of them joins the verify path,
    # at which point it belongs in the default branch below instead.
    scripts/*.ts | scripts/*.mjs | scripts/store-images/*) tooling=true ;;
    # The icon sync is part of verify-fast and has focused Ruby tests.
    scripts/sync-phosphor-icons.rb | scripts/sync-phosphor-icons.test.rb)
        app=true
        tooling=true
        ;;
    # The snapshot-result verifier has focused Ruby tests but is only used by
    # the explicit screenshot-recording tasks, not the regular app lane.
    scripts/verify-snapshot-recording.rb | scripts/verify-snapshot-recording.test.rb) tooling=true ;;
    package.json | pnpm-lock.yaml | pnpm-workspace.yaml | tsconfig.json) tooling=true ;;
    # Store artwork and the configs that drive it. A caption or a slot order
    # cannot break an iOS build, so these skip the macOS lane — but they do
    # invalidate the committed images, which the tooling lane checks.
    Config/Store*.json | fastlane/screenshots/*) tooling=true ;;
    *) app=true ;;
    esac
done

echo "app=$app"
echo "tooling=$tooling"
