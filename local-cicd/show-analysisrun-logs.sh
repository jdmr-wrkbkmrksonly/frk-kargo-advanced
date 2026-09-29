#!/usr/bin/env bash
# Prints logs for an AnalysisRun's underlying Job — a substitute for the Kargo UI's log
# streaming, which requires an external HTTP-fetchable log backend (Loki, etc.) we don't run on
# this disposable local cluster (see README.md). Defaults to the most recently created
# AnalysisRun; pass a name to target a specific one instead.
set -euo pipefail

NAMESPACE="${NAMESPACE:-kargo-advanced}"
RUN_NAME="${1:-}"

if [[ -z "$RUN_NAME" ]]; then
  RUN_NAME="$(kubectl get analysisruns -n "$NAMESPACE" \
    --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')"
  if [[ -z "$RUN_NAME" ]]; then
    echo "No AnalysisRuns found in namespace '$NAMESPACE'." >&2
    exit 1
  fi
  echo "==> No AnalysisRun name given, using the most recent: $RUN_NAME"
fi

RUN_UID="$(kubectl get analysisrun "$RUN_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"

JOB_NAME="$(kubectl get jobs -n "$NAMESPACE" -o json \
  | jq -r --arg uid "$RUN_UID" '.items[] | select(.metadata.ownerReferences[]?.uid==$uid) | .metadata.name')"

if [[ -z "$JOB_NAME" ]]; then
  echo "Could not find a Job owned by AnalysisRun '$RUN_NAME' (uid=$RUN_UID)." >&2
  exit 1
fi

echo "==> AnalysisRun: $RUN_NAME"
echo "==> Job:         $JOB_NAME"
echo "==> Logs:"
kubectl logs -n "$NAMESPACE" "job/$JOB_NAME"
