#!/usr/bin/env bash
# Installs the pinned asc CLI (https://asccli.sh) into ASC_INSTALL_DIR
# (default ~/.local/bin) after checking the release asset against the SHA-256
# below. Bump the version and every checksum together from the release's
# asc_<version>_checksums.txt.
set -euo pipefail

version="5.15.0"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) asset="asc_${version}_macOS_arm64" sha256="29b3f747acd94d1dc49884f4c0a7404181ec058c635d0ce20fc4202c930edf22" ;;
  Darwin-x86_64) asset="asc_${version}_macOS_amd64" sha256="4945df669cd2b59aeef64f1867c02b11e7f06558c251afbba96227d5b447fd8f" ;;
  Linux-aarch64 | Linux-arm64) asset="asc_${version}_linux_arm64" sha256="07203e9e961f44e376b5117852d8a11a043c8cfee9628e8471379e9c21b1a2c5" ;;
  Linux-x86_64) asset="asc_${version}_linux_amd64" sha256="614ae3190938f4826c8cfbbb836a1926f765963614c17fdeb86750883f71aa70" ;;
  *)
    echo "no pinned asc build for $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

install_dir="${ASC_INSTALL_DIR:-$HOME/.local/bin}"
download="$(mktemp -d)"
trap 'rm -rf "$download"' EXIT

curl --fail --silent --show-error --location --retry 3 \
  --output "$download/asc" \
  "https://github.com/rorkai/App-Store-Connect-CLI/releases/download/${version}/${asset}"
echo "${sha256}  $download/asc" | shasum -a 256 --check --status || {
  echo "$asset does not match its pinned SHA-256" >&2
  exit 1
}

mkdir -p "$install_dir"
install -m 0755 "$download/asc" "$install_dir/asc"

# asc version is exempt from telemetry; the variable keeps it that way if it changes.
installed="$(ASC_TELEMETRY_DISABLED=1 "$install_dir/asc" version)"
if [[ "$installed" != "$version "* ]]; then
  echo "installed asc reports $installed, expected $version" >&2
  exit 1
fi
echo "asc $version installed at $install_dir/asc"
