#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Lanes run in order; CI runs them on separate runners. Lanes share
# build/DerivedData, so never run two verify invocations in one worktree.
lanes=("$@")
if [[ ${#lanes[@]} -eq 0 ]]; then
  lanes=(tooling checks build ios tvos)
elif [[ "${lanes[0]}" == "--affected" ]]; then
  affected="$(node scripts/affected-lanes.ts "${lanes[@]:1}")"
  read -r -a selected <<<"$affected"
  lanes=()
  for lane in tooling checks build ios tvos; do
    [[ " ${selected[*]:-} " == *" $lane "* ]] && lanes+=("$lane")
  done
  printf 'verify: affected lanes: %s\n' "${lanes[*]:-none}"
  [[ ${#lanes[@]} -eq 0 ]] && exit 0
fi
for lane in "${lanes[@]}"; do
  case "$lane" in
    tooling | checks | build | ios | tvos) ;;
    *)
      printf 'unknown verify lane: %s (expected tooling, checks, build, ios, or tvos)\n' "$lane" >&2
      exit 64
      ;;
  esac
done

pnpm install --frozen-lockfile
for lane in "${lanes[@]}"; do
  if [[ "$lane" == build || "$lane" == ios || "$lane" == tvos ]]; then
    ./scripts/generate.sh
    break
  fi
done
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
  esac
done
