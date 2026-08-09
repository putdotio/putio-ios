#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

command -v xcodebuild >/dev/null || { echo "doctor: Xcode is required" >&2; exit 1; }
command -v tuist >/dev/null || { echo "doctor: run mise install" >&2; exit 1; }

xcode_version="$(xcodebuild -version | sed -n '1p')"
case "$xcode_version" in
    "Xcode 26"*) ;;
    *) echo "doctor: expected Xcode 26.x, found $xcode_version" >&2; exit 1 ;;
esac

echo "doctor: $xcode_version"
echo "doctor: Tuist $(tuist version)"
