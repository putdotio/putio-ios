#!/bin/sh

set -eu

bundle config set --local path vendor/bundle
bundle install

if [ -f Pods/Manifest.lock ] && cmp -s Podfile.lock Pods/Manifest.lock; then
  echo "Pods sandbox matches Podfile.lock, skipping pod install"
  exit 0
fi

echo "Pods sandbox missing or stale, running pod install"
bundle exec pod install
