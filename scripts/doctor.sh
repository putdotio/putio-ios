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
    echo "doctor: fix (persistent): sudo xcode-select -s \"$xcode_app\"" >&2
  else
    echo "doctor: fix: install Xcode from the App Store or https://developer.apple.com/download/" >&2
  fi
fi

exit "$status"
