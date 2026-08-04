#!/usr/bin/env bash
# Pull a prebuilt image from GitHub Container Registry and tag it claude-code:local
# so claude-box picks it up. No build, no login (the packages are public).
#
#   ./pull-image.sh              # latest base image
#   ./pull-image.sh node         # latest image with Node.js
#   ./pull-image.sh 2.1.220      # a specific claude version
#   ./pull-image.sh 2.1.220-node

set -euo pipefail

REGISTRY="${CLAUDE_BOX_REGISTRY:-ghcr.io/madpaura/claude-box}"
TAG="${1:-latest}"

echo "==> pulling $REGISTRY:$TAG"
docker pull "$REGISTRY:$TAG"
docker tag "$REGISTRY:$TAG" claude-code:local

echo
echo "==> tagged as claude-code:local"
docker image ls claude-code --format '    {{.Repository}}:{{.Tag}}  {{.Size}}'
echo
echo "Launch it in any folder with:  $(cd "$(dirname "$0")" && pwd)/claude-box"
