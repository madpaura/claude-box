#!/usr/bin/env bash
# Save the built image to a compressed archive for transfer to another machine.
#
#   ./save-image.sh                 # -> dist/claude-code-<version>.tar.zst
#   ./save-image.sh /path/out.tar.zst

set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${CLAUDE_BOX_IMAGE:-claude-code:local}"

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "save-image: image '$IMAGE' not found — run ./build.sh first" >&2; exit 1; }

VERSION="$(docker run --rm --entrypoint cat "$IMAGE" /etc/claude-code-version)"
NODE="$(docker run --rm --entrypoint cat "$IMAGE" /etc/node-version 2>/dev/null || echo none)"
[ "$NODE" != none ] && VERSION="$VERSION-node"

if command -v zstd >/dev/null 2>&1; then
  COMP=(zstd -T0 -3 -c); EXT=tar.zst
elif command -v pigz >/dev/null 2>&1; then
  COMP=(pigz -c); EXT=tar.gz
else
  COMP=(gzip -c); EXT=tar.gz
fi

REPO="${IMAGE%%:*}"
OUT="${1:-dist/$REPO-$VERSION.$EXT}"
mkdir -p "$(dirname "$OUT")"

# Save both the :local tag and the version tag, so the receiving machine can tell
# what it got.
TAGS=("$IMAGE")
docker image inspect "$REPO:$VERSION" >/dev/null 2>&1 && TAGS+=("$REPO:$VERSION")

echo "==> saving ${TAGS[*]} -> $OUT  [${COMP[0]}]"
docker save "${TAGS[@]}" | "${COMP[@]}" > "$OUT"

echo "==> done"
ls -lh "$OUT" | awk '{print "    size:   " $5 "  " $9}'
echo "    sha256: $(sha256sum "$OUT" | cut -d' ' -f1)"
echo
echo "Load it elsewhere with:  ./load-image.sh $(basename "$OUT")"
