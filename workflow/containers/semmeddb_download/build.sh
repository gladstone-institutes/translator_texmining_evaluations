#!/usr/bin/env bash
set -euo pipefail

# Docker image name. Change this (and containers.images.hello in config.yaml)
# when retargeting a different registry/account.
IMAGE="ruben6um/semmeddb-download"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION=$(sed -n 's/^LABEL version="\([^"]*\)"/\1/p' "${SCRIPT_DIR}/Dockerfile")
if [[ -z "${VERSION}" ]]; then
    echo "ERROR: could not extract version from Dockerfile" >&2
    exit 1
fi

TAG="${IMAGE}:${VERSION}"

PUSH=false
YES=false
NO_CACHE=""
PLAIN=""
for arg in "$@"; do
    case "${arg}" in
        --push)     PUSH=true ;;
        --yes|-y)   YES=true ;;
        --no-cache) NO_CACHE="--no-cache" ;;
        --plain)    PLAIN="--progress=plain" ;;
        *)
            echo "Usage: $0 [--push] [--yes] [--no-cache] [--plain]" >&2
            exit 1
            ;;
    esac
done

# Rebuilding an existing tag needs confirmation; --yes skips it. Without a
# terminal, `read` gets EOF and used to abort silently with exit 0.
if docker image inspect "${TAG}" &>/dev/null && ! ${YES}; then
    if [[ ! -t 0 ]]; then
        echo "Image ${TAG} already exists locally and stdin is not a terminal; pass --yes to overwrite." >&2
        exit 1
    fi
    read -rp "Image ${TAG} already exists locally. Overwrite? [y/N] " confirm
    if [[ "${confirm}" != [yY] ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo "Building ${TAG} ..."
docker build \
    --platform linux/amd64 \
    ${NO_CACHE} \
    ${PLAIN} \
    -t "${TAG}" \
    "${SCRIPT_DIR}"

if ${PUSH}; then
    echo "Pushing ${TAG} ..."
    docker push "${TAG}"
fi

echo "Done."
