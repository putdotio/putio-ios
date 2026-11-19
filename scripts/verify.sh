#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Lanes run in order; CI runs them on separate runners. Lanes share
# build/DerivedData, so never run two verify invocations in one worktree.
lanes=("$@")
[[ ${#lanes[@]} -eq 0 ]] && lanes=(tooling checks build ios tvos)
for lane in "${lanes[@]}"; do
  case "$lane" in
    tooling | checks | build | ios | tvos) ;;
    journeys)
      if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
        printf 'verify journeys needs a clean committed worktree; commit or pass other lanes\n' >&2
        exit 65
      fi
      ;;
    *)
      printf 'unknown verify lane: %s (expected tooling, checks, build, ios, tvos, or journeys)\n' "$lane" >&2
      exit 64
      ;;
  esac
done

pnpm install --frozen-lockfile
[[ "${lanes[*]}" != tooling ]] && ./scripts/generate.sh
for lane in "${lanes[@]}"; do
  case "$lane" in
    tooling) pnpm run verify ;;
    checks)
      ./scripts/doctor.sh
      ./scripts/test.sh
      ./scripts/test-harness-interruption.sh
      ;;
    build) ./scripts/build.sh ;;
    ios | tvos) ./scripts/harness.sh test --platform "$lane" ;;
    journeys) ./scripts/harness.sh journey --platform ios --scenario files-browser ;;
  esac
done
