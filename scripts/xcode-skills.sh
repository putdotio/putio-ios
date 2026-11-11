#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export_dir="build/xcode-skills"
rm -rf "$export_dir"
mkdir -p "$export_dir"
xcrun agent skills export --output-dir "$repo_root/$export_dir"

exclude_file="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$exclude_file")"
touch "$exclude_file"

for skill_dir in "$export_dir"/*/; do
    name="$(basename "$skill_dir")"
    for skills_root in .agents/skills .claude/skills; do
        link="$skills_root/$name"
        if git ls-files --error-unmatch "$link" >/dev/null 2>&1; then
            printf 'xcode-skills: skipped %s; the repository tracks that name\n' "$link" >&2
            continue
        fi
        ln -sfn "../../$export_dir/$name" "$link"
        grep -qxF "/$link" "$exclude_file" || printf '/%s\n' "$link" >>"$exclude_file"
    done
done
