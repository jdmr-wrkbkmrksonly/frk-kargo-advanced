#!/usr/bin/env bash
# Local-only helper: strips the argocd-update step from the "promote" PromotionTask so full
# Stage promotions (dev -> staging -> perf-test) can complete on a cluster with no real Argo CD
# installed (this is the "stay minimal" local-cicd setup — see README.md).
#
# This patches the LIVE cluster object only. It never edits any committed kargo/promotiontasks.yaml
# in this repo (or your fork) — production still needs argocd-update to actually sync the app.
# Safe to re-run (no-ops if already patched). To restore it, just re-apply the real file:
#   kubectl apply -f <your-repo>/kargo/promotiontasks.yaml
set -euo pipefail

PROJECT="${PROJECT:-kargo-advanced}"
TASK="${TASK:-promote}"

echo "==> Removing the argocd-update step from PromotionTask '$TASK' in namespace '$PROJECT' (live cluster only)"

CURRENT_STEPS="$(kubectl get promotiontask "$TASK" -n "$PROJECT" -o json | jq '.spec.steps')"
FILTERED_STEPS="$(echo "$CURRENT_STEPS" | jq '[.[] | select(.uses != "argocd-update")]')"

REMOVED=$(( $(echo "$CURRENT_STEPS" | jq 'length') - $(echo "$FILTERED_STEPS" | jq 'length') ))
if [[ "$REMOVED" -eq 0 ]]; then
  echo "    no argocd-update step found — nothing to do (already patched, or task shape differs)"
  exit 0
fi

kubectl patch promotiontask "$TASK" -n "$PROJECT" --type=merge \
  -p "$(jq -n --argjson steps "$FILTERED_STEPS" '{spec:{steps:$steps}}')"

echo "==> Done. Removed $REMOVED step(s) (vars and everything else are untouched)."
echo "    Restore the real behavior later with: kubectl apply -f <your-repo>/kargo/promotiontasks.yaml"
