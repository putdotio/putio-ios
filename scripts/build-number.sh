#!/usr/bin/env bash
set -euo pipefail

read -r day minute < <(date -u '+%y%m%d %H%M')
echo "$day.$((10#$minute))"
