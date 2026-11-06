#!/bin/sh

set -eu

mise install swiftlint

bundle config set --local path vendor/bundle
bundle install

if [ -f Pods/Manifest.lock ] && cmp -s Podfile.lock Pods/Manifest.lock; then
  echo "Pods sandbox matches Podfile.lock, skipping pod install"
else
  echo "Pods sandbox missing or stale, running pod install"
  bundle exec pod install
fi

xcodebuild -resolvePackageDependencies -workspace Putio.xcworkspace -scheme Putio \
  -onlyUsePackageVersionsFromResolvedFile -quiet
