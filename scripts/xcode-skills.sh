#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export_dir="build/xcode-skills"
staging_dir="$export_dir.staging"
timeout_seconds="${PUTIO_XCODE_SKILLS_TIMEOUT:-120}"
skills_roots=(.agents/skills .claude/skills)

xcode_was_running=0
pgrep -x Xcode >/dev/null 2>&1 && xcode_was_running=1

quit_started_xcode() {
    rm -rf "$staging_dir"
    if [[ "$xcode_was_running" == 0 ]]; then
        local pid
        for pid in $(pgrep -x Xcode 2>/dev/null || true); do
            kill "$pid" 2>/dev/null || true
        done
    fi
}
trap quit_started_xcode EXIT

rm -rf "$staging_dir"
mkdir -p "$staging_dir"
xcrun agent skills export --output-dir "$repo_root/$staging_dir" >/dev/null &
export_pid=$!
deadline=$((SECONDS + timeout_seconds))
while kill -0 "$export_pid" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
        kill "$export_pid" 2>/dev/null || true
        printf 'xcode-skills: export did not finish within %s seconds; Xcode may be waiting for approval in its window\n' "$timeout_seconds" >&2
        exit 1
    fi
    sleep 1
done
wait "$export_pid"

exported=("$staging_dir"/*/)
if ((${#exported[@]} == 0)); then
    printf 'xcode-skills: Xcode exported no skills\n' >&2
    exit 1
fi

rm -rf "$export_dir"
mv "$staging_dir" "$export_dir"

for skills_root in "${skills_roots[@]}"; do
    for link in "$skills_root"/*; do
        if [[ -L "$link" && "$(readlink "$link")" == "../../$export_dir/"* && ! -e "$link" ]]; then
            rm "$link"
        fi
    done
done

exclude_file="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$exclude_file")"
touch "$exclude_file"

for skill_dir in "$export_dir"/*/; do
    name="$(basename "$skill_dir")"
    for skills_root in "${skills_roots[@]}"; do
        link="$skills_root/$name"
        if git ls-files --error-unmatch "$link" >/dev/null 2>&1 || [[ -e "$link" && ! -L "$link" ]]; then
            printf 'xcode-skills: skipped %s; the checkout already has that name\n' "$link" >&2
            continue
        fi
        ln -sfn "../../$export_dir/$name" "$link"
        grep -qxF "/$link" "$exclude_file" || printf '/%s\n' "$link" >>"$exclude_file"
    done
done

printf 'xcode-skills: linked %s skills from %s\n' "${#exported[@]}" "$export_dir"
