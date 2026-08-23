#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

pnpm install --frozen-lockfile
./scripts/generate.sh
./scripts/doctor.sh
./scripts/test.sh
./scripts/build.sh
./scripts/harness.sh test --platform ios
./scripts/harness.sh test --platform tvos
