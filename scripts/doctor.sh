#!/bin/sh

# Preflight environment checks with copy-pasteable fixes. Runs before
# bootstrap and on demand via `make doctor`. Exits non-zero when the
# environment cannot run bootstrap/verify targets.

set -eu

# Run in the repo rather than wherever doctor was invoked from. Both halves of
# every check have to agree on which checkout they mean: corepack resolves pnpm
# against the nearest package.json, so reading the pin here while probing the
# version there would compare this repo's expectation to another directory's
# toolchain.
cd -- "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

status=0

# Reads one pin out of mise.toml's [tools] table. Scoped to that table so a
# task or setting sharing a tool's name cannot answer in its place.
mise_tool_version() {
  awk -v tool="$1" '
    /^[[:space:]]*\[/ { in_tools = ($0 ~ /^[[:space:]]*\[tools\][[:space:]]*$/); next }
    in_tools && $1 == tool && match($0, /"[^"]*"/) {
      print substr($0, RSTART + 1, RLENGTH - 2)
      exit
    }
  ' mise.toml
}

check_tool() {
  tool="$1"
  actual="$2"
  expected="$(mise_tool_version "$tool")"

  if [ -z "$expected" ]; then
    status=1
    echo "doctor: mise.toml has no [tools] entry for $tool" >&2
    return
  fi

  if [ "$actual" = "$expected" ]; then
    echo "doctor: $tool $actual matches mise.toml"
    return
  fi

  status=1
  echo "doctor: active $tool is $actual but mise.toml wants $expected" >&2
  mise_bin="$HOME/.local/share/mise/installs/$tool/$expected/bin"
  if [ -d "$mise_bin" ]; then
    echo "doctor: fix: export PATH=\"$mise_bin:\$PATH\"" >&2
  else
    echo "doctor: fix: mise install, then put $tool $expected first in PATH" >&2
  fi
}

check_tool ruby "$(ruby -e 'print RUBY_VERSION' 2>/dev/null || echo "missing")"
check_tool node "$(node -e 'process.stdout.write(process.versions.node)' 2>/dev/null || echo "missing")"

# pnpm ships via corepack, which is bundled with node, so package.json's
# packageManager field stays its single pin rather than moving to mise.toml —
# two pins would have to be bumped together. Checked all the same, because
# corepack honours that field only when a standalone pnpm on PATH is not
# silently winning and resolving dependencies differently from the lockfile.
expected_pnpm="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"pnpm@\([^"]*\)".*/\1/p' package.json)"
actual_pnpm="$(pnpm --version 2>/dev/null || echo "missing")"

if [ -z "$expected_pnpm" ]; then
  status=1
  echo "doctor: package.json has no \"packageManager\": \"pnpm@<version>\" entry" >&2
elif [ "$actual_pnpm" = "$expected_pnpm" ]; then
  echo "doctor: pnpm $actual_pnpm matches packageManager"
elif [ "$actual_pnpm" = "missing" ]; then
  status=1
  echo "doctor: pnpm is not on PATH but package.json wants pnpm@$expected_pnpm" >&2
  echo "doctor: fix: corepack enable" >&2
else
  status=1
  echo "doctor: active pnpm is $actual_pnpm but package.json pins pnpm@$expected_pnpm" >&2
  echo "doctor: fix: corepack enable && corepack prepare pnpm@$expected_pnpm --activate" >&2
fi

developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo "missing")}"

developer_dir_ok=0
case "$developer_dir" in
  missing|*CommandLineTools*) ;;
  *)
    if [ -x "$developer_dir/usr/bin/xcodebuild" ]; then
      developer_dir_ok=1
    fi
    ;;
esac

if [ "$developer_dir_ok" = "1" ]; then
  echo "doctor: developer directory is $developer_dir"
else
  status=1
  echo "doctor: xcodebuild needs a full Xcode but the active developer directory is $developer_dir" >&2
  xcode_app="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -n 1 || true)"
  if [ -n "$xcode_app" ]; then
    echo "doctor: fix: export DEVELOPER_DIR=\"$xcode_app/Contents/Developer\"" >&2
    echo "doctor: fix (persistent): sudo xcode-select -s \"$xcode_app/Contents/Developer\"" >&2
  else
    echo "doctor: fix: install Xcode from the App Store or https://developer.apple.com/download/" >&2
  fi
fi

exit "$status"
