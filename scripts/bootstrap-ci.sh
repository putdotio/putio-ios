#!/bin/sh

set -eu

mise install swiftlint

xcodebuild -resolvePackageDependencies -workspace Putio.xcworkspace -scheme Putio \
  -onlyUsePackageVersionsFromResolvedFile -quiet
