#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

pnpm run verify
# Sentry is reachable only through the telemetry redaction boundary (#150), so
# no capture can skip it.
if git grep --untracked -nE '^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*import[[:space:]]+([a-z]+[[:space:]]+)?Sentry[A-Za-z_]*([.[:space:]]|$)' \
  -- 'Apps/*.swift' 'Packages/*.swift' ':(exclude)Apps/iOS/Sources/Telemetry/SentryTelemetry.swift'; then
  echo "test: import Sentry only in Apps/iOS/Sources/Telemetry/SentryTelemetry.swift." >&2
  exit 1
fi
# Intercom gets only the support identity, through one client.
if git grep --untracked -nE '^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*import[[:space:]]+([a-z]+[[:space:]]+)?Intercom([.[:space:]]|$)' \
  -- 'Apps/*.swift' 'Packages/*.swift' ':(exclude)Apps/iOS/Sources/Support/IntercomSupportClient.swift'; then
  echo "test: import Intercom only in IntercomSupportClient.swift." >&2
  exit 1
fi
swift format lint --strict --recursive Apps Packages Tests Tools Project.swift Tuist.swift Tuist/Package.swift
swift test --package-path Packages/PutioCore
swift test --package-path Tools/PutioHarness
