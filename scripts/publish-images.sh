#!/usr/bin/env bash
# Builds and pushes the three BlakTail images to ECR.
# Usage: scripts/publish-images.sh <aws-account-id> [region] [tag]
set -euo pipefail

ACCOUNT="${1:?usage: publish-images.sh <aws-account-id> [region] [tag]}"
REGION="${2:-ap-southeast-2}"
TAG="${3:-latest}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

build_push() {
    local repo="$1" dockerfile="$2"
    docker build --platform linux/arm64 -f "$ROOT/$dockerfile" -t "$REGISTRY/$repo:$TAG" "$ROOT"
    docker push "$REGISTRY/$repo:$TAG"
    echo "pushed $REGISTRY/$repo:$TAG"
}

build_push "blaktail/coord"   "deploy/docker/coord.Dockerfile"
build_push "blaktail/relay"   "deploy/docker/relay.Dockerfile"
build_push "blaktail/console" "apps/console/Dockerfile"
