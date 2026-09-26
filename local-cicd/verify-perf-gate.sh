#!/usr/bin/env bash
# Directly validates the locust-perf-test AnalysisTemplate's Job/exit-code mechanics, without
# going through a full Kargo Stage/Promotion/Freight flow. Splices the live AnalysisTemplate's
# `spec.metrics` (so there's a single source of truth: kargo/analysis.yaml — nothing is
# hand-duplicated here) into a standalone AnalysisRun, which Kargo's own controller reconciles
# exactly as it would one materialized from a Stage's `verification` block.
set -euo pipefail

NAMESPACE="kargo-advanced"
TEMPLATE="locust-perf-test"

HOST="${HOST:-http://guestbook.guestbook-perf-test.svc.cluster.local}"
USERS="${USERS:-20}"
SPAWN_RATE="${SPAWN_RATE:-5}"
RUN_TIME="${RUN_TIME:-1m}"
MAX_FAIL_RATIO="${MAX_FAIL_RATIO:-0.01}"
MAX_P95_MS="${MAX_P95_MS:-500}"
TIMEOUT_SECS="${TIMEOUT_SECS:-180}"

if [[ "${1:-}" == "--fail-scenario" ]]; then
  echo "==> --fail-scenario: forcing an unachievable p95 threshold to prove the gate fails closed"
  MAX_P95_MS=1
fi

if ! kubectl get analysistemplate "$TEMPLATE" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "AnalysisTemplate '$TEMPLATE' not found in namespace '$NAMESPACE' — run ./setup.sh first." >&2
  exit 1
fi

RUN_NAME="locust-perf-test-manual-$(date +%s)"

echo "==> Creating AnalysisRun '$RUN_NAME' (host=$HOST users=$USERS spawnRate=$SPAWN_RATE runTime=$RUN_TIME maxFailRatio=$MAX_FAIL_RATIO maxP95Ms=$MAX_P95_MS)"

kubectl get analysistemplate "$TEMPLATE" -n "$NAMESPACE" -o json | jq \
  --arg name "$RUN_NAME" \
  --arg namespace "$NAMESPACE" \
  --arg host "$HOST" \
  --arg users "$USERS" \
  --arg spawnRate "$SPAWN_RATE" \
  --arg runTime "$RUN_TIME" \
  --arg maxFailRatio "$MAX_FAIL_RATIO" \
  --arg maxP95Ms "$MAX_P95_MS" \
  '{
    apiVersion: "argoproj.io/v1alpha1",
    kind: "AnalysisRun",
    metadata: { name: $name, namespace: $namespace },
    spec: {
      args: [
        { name: "host", value: $host },
        { name: "users", value: $users },
        { name: "spawnRate", value: $spawnRate },
        { name: "runTime", value: $runTime },
        { name: "maxFailRatio", value: $maxFailRatio },
        { name: "maxP95Ms", value: $maxP95Ms }
      ],
      metrics: .spec.metrics
    }
  }' | kubectl create -f -

cleanup() {
  echo "==> Deleting AnalysisRun '$RUN_NAME'"
  kubectl delete analysisrun "$RUN_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

RUN_UID="$(kubectl get analysisrun "$RUN_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"

echo "==> Waiting for the Job Kargo creates for this AnalysisRun..."
JOB_NAME=""
for i in $(seq 1 30); do
  JOB_NAME="$(kubectl get jobs -n "$NAMESPACE" -o json \
    | jq -r --arg uid "$RUN_UID" '.items[] | select(.metadata.ownerReferences[]?.uid==$uid) | .metadata.name' \
    | head -n1)"
  [[ -n "$JOB_NAME" ]] && break
  sleep 2
done

if [[ -n "$JOB_NAME" ]]; then
  echo "==> Tailing logs for Job '$JOB_NAME' (Ctrl-C to stop tailing without aborting the run)"
  kubectl wait --for=condition=Ready --timeout=60s pod -l job-name="$JOB_NAME" -n "$NAMESPACE" 2>/dev/null || true
  kubectl logs -f "job/$JOB_NAME" -n "$NAMESPACE" 2>/dev/null || true
else
  echo "==> Warning: could not locate the Job for this AnalysisRun within the timeout; continuing to poll phase" >&2
fi

echo "==> Waiting for AnalysisRun phase (timeout: ${TIMEOUT_SECS}s)"
PHASE="Pending"
ELAPSED=0
while [[ "$PHASE" != "Successful" && "$PHASE" != "Failed" && "$PHASE" != "Error" && "$ELAPSED" -lt "$TIMEOUT_SECS" ]]; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  PHASE="$(kubectl get analysisrun "$RUN_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo Pending)"
done

echo
echo "==> AnalysisRun '$RUN_NAME' finished with phase: $PHASE"

if [[ "$PHASE" == "Successful" ]]; then
  echo "PASS: the locust-perf-test gate reported the run as Verified."
  exit 0
else
  echo "FAIL: the locust-perf-test gate reported the run as $PHASE (this is expected with --fail-scenario)."
  exit 1
fi
