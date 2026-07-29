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
    # Node tooling. The app target builds with no Node involvement, so these
    # reach the type-check lane only — until one of them joins the verify path,
    # at which point it belongs in the default branch below instead.
    scripts/*.ts | scripts/*.mjs | scripts/store-images/*) tooling=true ;;
    package.json | pnpm-lock.yaml | tsconfig.json) tooling=true ;;
    *) app=true ;;
    esac
done

echo "app=$app"
echo "tooling=$tooling"
