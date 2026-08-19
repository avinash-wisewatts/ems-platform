#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="$ROOT/grafana/plugin-src/wisewatts-live-datasource"
OUT="$ROOT/grafana/plugins/wisewatts-live-datasource"

UID_HOST="$(id -u)"
GID_HOST="$(id -g)"

echo "=== WiseWatts Grafana Live plugin build ==="
echo "Source: $SRC"
echo "Output: $OUT"
echo "Builder UID:GID = ${UID_HOST}:${GID_HOST}"

# Clean source-side build output only.
rm -rf "$SRC/dist"
mkdir -p "$SRC/dist"

# The plugin output directory must already exist and be writable by emsadmin.
if [ ! -d "$OUT" ]; then
    echo "ERROR: output directory does not exist: $OUT"
    echo "Create it once with:"
    echo "  sudo mkdir -p '$OUT'"
    echo "  sudo chown $(id -un):$(id -gn) '$OUT'"
    exit 1
fi

if [ ! -w "$OUT" ]; then
    echo "ERROR: output directory is not writable: $OUT"
    echo "Fix with:"
    echo "  sudo chown -R $(id -un):$(id -gn) '$OUT'"
    exit 1
fi

rm -rf "$OUT"/*

echo
echo "=== Frontend build ==="

docker run --rm \
  --user "${UID_HOST}:${GID_HOST}" \
  -e HOME=/tmp \
  -e npm_config_cache=/tmp/npm-cache \
  -v "$SRC:/src" \
  -w /src \
  node:22-bookworm \
  bash -c 'npm install --no-audit --no-fund && npm run build'

echo
echo "=== Backend build ==="

docker run --rm \
  --user "${UID_HOST}:${GID_HOST}" \
  -e HOME=/tmp \
  -e GOCACHE=/tmp/go-build-cache \
  -e GOMODCACHE=/tmp/go-mod-cache \
  -v "$SRC:/src" \
  -w /src \
  golang:1.23-bookworm \
  bash -c '
    set -e
    /usr/local/go/bin/go version
    /usr/local/go/bin/go mod tidy
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      /usr/local/go/bin/go build \
      -o dist/wisewatts_live_datasource_linux_amd64 .
  '

echo
echo "=== Installing plugin artifact ==="

cp -a "$SRC/dist/." "$OUT/"

# Grafana runs as its own container UID and must be able to traverse/read
# every plugin artifact regardless of the invoking shell's umask.
find "$OUT" -type d -exec chmod 0755 {} +
find "$OUT" -type f -exec chmod 0644 {} +
chmod 0755 "$OUT/wisewatts_live_datasource_linux_amd64"

echo
echo "=== BUILD COMPLETE ==="
find "$OUT" -maxdepth 2 -type f -printf '%P\n' | sort
