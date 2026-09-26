#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="kargo-advanced-local"
export KIND_EXPERIMENTAL_PROVIDER=podman

echo "==> Deleting kind cluster '$CLUSTER_NAME'"
kind delete cluster --name "$CLUSTER_NAME"
