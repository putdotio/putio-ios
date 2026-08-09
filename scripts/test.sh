#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

swift format lint --strict --recursive Apps Packages Project.swift Tuist.swift Tuist/Package.swift
swift test --package-path Packages/PutioCore
