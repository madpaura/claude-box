#!/usr/bin/env bash
# Build the minimal Claude Code image.
#
#   ./build.sh                        # latest stable release, no Node
#   ./build.sh latest                 # newest release
#   ./build.sh 2.1.220                # pinned claude version
#   ./build.sh --node                 # also install Node.js + npm (current LTS)
#   ./build.sh 2.1.220 --node --node-version v24.19.0
#
# The image user is created with your host uid/gid/username so files written into
# mounted folders come out owned by you.

set -euo pipefail
cd "$(dirname "$0")"

VERSION=stable
WITH_NODE=0
NODE_VERSION=lts
IMAGE=claude-code

while [ $# -gt 0 ]; do
  case "$1" in
    --node)         WITH_NODE=1; shift ;;
    --node-version) [ $# -ge 2 ] || { echo "build: --node-version needs a value" >&2; exit 2; }
                    WITH_NODE=1; NODE_VERSION="$2"; shift 2 ;;
    -h|--help)      sed -n '2,12p' "$0"; exit 0 ;;
    -*)             echo "build: unknown option: $1" >&2; exit 2 ;;
    *)              VERSION="$1"; shift ;;
  esac
done

echo "==> building $IMAGE (claude: $VERSION, node: $([ "$WITH_NODE" = 1 ] && echo "$NODE_VERSION" || echo no), user: $(id -un) $(id -u):$(id -g))"

docker build \
  --build-arg "CLAUDE_VERSION=$VERSION" \
  --build-arg "WITH_NODE=$WITH_NODE" \
  --build-arg "NODE_VERSION=$NODE_VERSION" \
  --build-arg "USERNAME=$(id -un)" \
  --build-arg "UID=$(id -u)" \
  --build-arg "GID=$(id -g)" \
  -t "$IMAGE:local" \
  .

RESOLVED="$(docker run --rm --entrypoint cat "$IMAGE:local" /etc/claude-code-version)"
NODE_RESOLVED="$(docker run --rm --entrypoint cat "$IMAGE:local" /etc/node-version)"
TAG="$RESOLVED"
[ "$NODE_RESOLVED" != none ] && TAG="$RESOLVED-node"
docker tag "$IMAGE:local" "$IMAGE:$TAG"

echo
echo "==> built $IMAGE:local (also tagged $IMAGE:$TAG)"
[ "$NODE_RESOLVED" != none ] && echo "    node:   $NODE_RESOLVED"
docker image ls "$IMAGE" --format '    {{.Repository}}:{{.Tag}}  {{.Size}}'
echo
echo "Launch it in any folder with:  $(pwd)/claude-box"
