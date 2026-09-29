#!/usr/bin/env bash
# Applies your fork's kargo/ manifests to the local-cicd cluster, then re-strips argocd-update
# from the live promote PromotionTask (kargo/promotiontasks.yaml unconditionally restores it on
# every apply, since there's no real Argo CD here -- see disable-argocd-update.sh). Run this after
# every `git push` to your fork instead of the two steps separately.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="kargo-advanced-local"
FORK_DIR="${FORK_DIR:-/Users/jose.morales/Workspaces/Prsnl/ArgoCDProjects/kargo/frk-kargo-advanced}"

export KIND_EXPERIMENTAL_PROVIDER=podman
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

if [[ ! -d "$FORK_DIR/kargo" ]]; then
  echo "FORK_DIR '$FORK_DIR' has no kargo/ directory -- set FORK_DIR to your fork's checkout path." >&2
  exit 1
fi

echo "==> Applying $FORK_DIR/kargo"
kubectl apply -f "$FORK_DIR/kargo"

echo "==> Re-stripping argocd-update from the live promote PromotionTask"
"$SCRIPT_DIR/disable-argocd-update.sh"

echo "==> Done. Cluster is in sync with $FORK_DIR."
