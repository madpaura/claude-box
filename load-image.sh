#!/usr/bin/env bash
# Load an image archive produced by save-image.sh and tag it claude-code:local
# so claude-box picks it up.
#
#   ./load-image.sh dist/claude-code-2.1.220.tar.zst

set -euo pipefail
cd "$(dirname "$0")"

FILE="${1:-}"
[ -n "$FILE" ] && [ -f "$FILE" ] || {
  echo "usage: ./load-image.sh <image.tar.zst|.tar.gz|.tar>" >&2; exit 2; }

case "$FILE" in
  *.tar.zst|*.tzst) DECOMP=(zstd -dc) ;;
  *.tar.gz|*.tgz)   DECOMP=(gzip -dc) ;;
  *.tar)            DECOMP=(cat) ;;
  *) echo "load-image: unrecognised extension: $FILE" >&2; exit 2 ;;
esac

command -v "${DECOMP[0]}" >/dev/null 2>&1 || {
  echo "load-image: ${DECOMP[0]} is not installed" >&2; exit 1; }

echo "==> loading $FILE"
"${DECOMP[@]}" "$FILE" | docker load

# Whatever version tag came in, make claude-code:local point at it.
if ! docker image inspect claude-code:local >/dev/null 2>&1; then
  TAG="$(docker image ls claude-code --format '{{.Tag}}' | grep -v '^local$' | head -1)"
  [ -n "$TAG" ] || { echo "load-image: no claude-code image found after load" >&2; exit 1; }
  docker tag "claude-code:$TAG" claude-code:local
  echo "==> tagged claude-code:$TAG as claude-code:local"
fi

echo
docker image ls claude-code --format '    {{.Repository}}:{{.Tag}}  {{.Size}}'
echo
echo "Launch it in any folder with:  $(pwd)/claude-box"
