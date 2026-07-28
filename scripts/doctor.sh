#!/bin/sh

# Preflight environment checks with copy-pasteable fixes. Runs before
# bootstrap and on demand via `make doctor`. Exits non-zero when the
# environment cannot run bootstrap/verify targets.

set -eu

status=0

expected_ruby="$(cat .ruby-version)"
actual_ruby="$(ruby -e 'print RUBY_VERSION' 2>/dev/null || echo "missing")"

if [ "$actual_ruby" = "$expected_ruby" ]; then
  echo "doctor: ruby $actual_ruby matches .ruby-version"
else
  status=1
  echo "doctor: active ruby is $actual_ruby but .ruby-version wants $expected_ruby" >&2
  mise_ruby_bin="$HOME/.local/share/mise/installs/ruby/$expected_ruby/bin"
  if [ -d "$mise_ruby_bin" ]; then
    echo "doctor: fix: export PATH=\"$mise_ruby_bin:\$PATH\"" >&2
  else
    echo "doctor: fix: install ruby $expected_ruby (e.g. mise install ruby@$expected_ruby) and put it first in PATH" >&2
  fi
fi

expected_node="$(cat .node-version)"
actual_node="$(node -e 'process.stdout.write(process.versions.node)' 2>/dev/null || echo "missing")"

if [ "$actual_node" = "$expected_node" ]; then
  echo "doctor: node $actual_node matches .node-version"
else
  status=1
  echo "doctor: active node is $actual_node but .node-version wants $expected_node" >&2
  mise_node_bin="$HOME/.local/share/mise/installs/node/$expected_node/bin"
  if [ -d "$mise_node_bin" ]; then
    echo "doctor: fix: export PATH=\"$mise_node_bin:\$PATH\"" >&2
  else
    echo "doctor: fix: install node $expected_node (e.g. mise install node@$expected_node) and put it first in PATH" >&2
  fi
fi

# pnpm ships via corepack, which is bundled with node; the version comes from
# packageManager in package.json.
if command -v pnpm >/dev/null 2>&1; then
  echo "doctor: pnpm $(pnpm --version 2>/dev/null || echo "unknown") is available"
else
  status=1
  echo "doctor: pnpm is not on PATH" >&2
  echo "doctor: fix: corepack enable" >&2
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
