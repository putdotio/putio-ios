#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

output_format="text"
arguments=("$@")
for ((index = 0; index < ${#arguments[@]}; index++)); do
    if [[ "${arguments[$index]}" == "--output" && "${arguments[$((index + 1))]:-}" == "json" ]]; then
        output_format="json"
    fi
done

fail_preflight() {
    local name="$1"
    local detail="$2"
    if [[ "$output_format" == "json" ]]; then
        detail="${detail//\\/\\\\}"
        detail="${detail//\"/\\\"}"
        printf '{"checks":[{"detail":"%s","name":"%s","required":true,"status":"failed"}],"status":"failed"}\n' "$detail" "$name" >&2
    else
        printf 'doctor: failed\nfailed: %s: %s\n' "$name" "$detail" >&2
    fi
    exit 1
}

command -v swift >/dev/null 2>&1 || fail_preflight "swift" "missing; install Xcode 26.x"
command -v xcodebuild >/dev/null 2>&1 || fail_preflight "xcodebuild" "missing; install Xcode 26.x and select it with DEVELOPER_DIR"

swift_output="$(swift --version 2>/dev/null || true)"
swift_version="$(printf '%s\n' "$swift_output" | sed -n '1{s/.*Apple Swift version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1.\2/p;}')"
swift_major="${swift_version%%.*}"
swift_minor="${swift_version#*.}"
if [[ -z "$swift_version" || "$swift_major" -lt 6 || ( "$swift_major" -eq 6 && "$swift_minor" -lt 2 ) ]]; then
    fail_preflight "swift-version" "expected Swift 6.2 or newer, found ${swift_version:-unknown}; select Xcode 26.x"
fi

xcode_output="$(xcodebuild -version 2>/dev/null || true)"
xcode_version="$(printf '%s\n' "$xcode_output" | sed -n '1p')"
case "$xcode_version" in
    "Xcode 26"*) ;;
    *) fail_preflight "xcode-version" "expected Xcode 26.x, found ${xcode_version:-unknown}; select Xcode 26.x with DEVELOPER_DIR" ;;
esac

exec ./scripts/harness.sh doctor "$@"
