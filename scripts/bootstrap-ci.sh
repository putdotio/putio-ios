#!/bin/sh

set -eu

mise install swiftlint node

xcodebuild -resolvePackageDependencies -workspace Putio.xcworkspace -scheme Putio \
  -onlyUsePackageVersionsFromResolvedFile -quiet
