#!/usr/bin/env bash
# Spins up a disposable kind (Podman-backed) cluster and installs just enough to validate the
# locust-perf-test verification gate: cert-manager (Kargo's Helm chart requires it for its
# webhook/API cert, even with a self-signed cert), Argo Rollouts CRDs (Kargo's controller
# reconciles AnalysisRun itself, but the AnalysisTemplate/AnalysisRun CRDs must already exist),
# and Kargo. No Argo CD, no git server — this repo's kargo/ manifests are applied as-is and
# guestbook is deployed straight via kubectl, since we're validating verification, not deployment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME="kargo-advanced-local"

export KIND_EXPERIMENTAL_PROVIDER=podman

echo "==> Creating kind cluster '$CLUSTER_NAME' (provider: podman)"
# NOTE: `kind get clusters` is broken with this kind/podman combo (podman's `ps --format` renders
# .Labels as a string, but kind's template does `index .Labels "..."` expecting a map -> "cannot
# index slice/array with type string"). Detect an existing, healthy cluster via kubectl instead
# (kind create/delete cluster both work fine — only `get clusters` hits this).
if kubectl config get-contexts -o name 2>/dev/null | grep -qx "kind-$CLUSTER_NAME" \
  && kubectl --context "kind-$CLUSTER_NAME" get nodes >/dev/null 2>&1; then
  echo "    cluster already exists and is reachable, reusing it"
else
  # Clean up leftover node container(s) from a previous failed/partial create — `kind create`
  # fails with "node(s) already exist" if these are left behind (podman doesn't auto-remove them
  # on a failed/interrupted run).
  STALE="$(podman ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${CLUSTER_NAME}-(control-plane|worker[0-9]*)$" || true)"
  if [[ -n "$STALE" ]]; then
    echo "    found stale node container(s) from a previous run, removing them:"
    echo "$STALE" | sed 's/^/      /'
    echo "$STALE" | xargs -r podman rm -f >/dev/null
  fi
  kind create cluster --name "$CLUSTER_NAME" --config "$SCRIPT_DIR/kind-config.yaml"
fi

kubectl config use-context "kind-$CLUSTER_NAME"

echo "==> Installing cert-manager"
# --server-side: these upstream manifests embed CRDs with OpenAPI schemas large enough that a
# regular `kubectl apply` last-applied-configuration annotation blows past the 262144-byte cap
# (metadata.annotations: Too long). Server-side apply tracks field ownership instead, no such limit.
kubectl apply --server-side --force-conflicts \
  -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl -n cert-manager wait --for=condition=Available --timeout=180s \
  deployment/cert-manager deployment/cert-manager-webhook deployment/cert-manager-cainjector

echo "==> Installing Argo Rollouts CRDs (AnalysisTemplate/AnalysisRun) — controller not required to run"
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts \
  -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl wait --for=condition=Established --timeout=120s \
  crd/analysistemplates.argoproj.io crd/analysisruns.argoproj.io crd/clusteranalysistemplates.argoproj.io

echo "==> Generating throwaway Kargo admin credentials (local cluster only)"
ADMIN_PASSWORD_HASH="$(htpasswd -nbBC 10 admin admin | cut -d: -f2)"
TOKEN_SIGNING_KEY="$(openssl rand -base64 48)"

echo "==> Installing Kargo"
helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
  --namespace kargo --create-namespace --wait --timeout 5m \
  --set api.adminAccount.passwordHash="$ADMIN_PASSWORD_HASH" \
  --set api.adminAccount.tokenSigningKey="$TOKEN_SIGNING_KEY" \
  --set api.tls.selfSignedCert=true \
  --set api.ingress.enabled=false \
  --set api.service.type=ClusterIP

echo "==> Applying the Project first — Kargo's controller reconciles it into the kargo-advanced"
echo "    Namespace asynchronously, which every other manifest here lives in"
kubectl apply -f "$REPO_ROOT/kargo/project.yaml"
for i in $(seq 1 30); do
  if kubectl get ns kargo-advanced >/dev/null 2>&1; then break; fi
  sleep 2
done
kubectl get ns kargo-advanced >/dev/null

echo "==> Applying the rest of this repo's kargo/ manifests (Warehouse, Stages, PromotionTask, AnalysisTemplates, ConfigMap)"
kubectl apply -f "$REPO_ROOT/kargo"

echo "==> Waiting for the AnalysisTemplate to be present"
for i in $(seq 1 30); do
  if kubectl get analysistemplate locust-perf-test -n kargo-advanced >/dev/null 2>&1; then break; fi
  sleep 2
done
kubectl get analysistemplate locust-perf-test -n kargo-advanced >/dev/null

echo "==> Deploying guestbook directly into guestbook-perf-test (bypassing Argo CD)"
kubectl apply -k "$REPO_ROOT/env/perf-test"
kubectl -n guestbook-perf-test wait --for=condition=Available --timeout=180s deployment/guestbook

cat <<EOF

==> Setup complete.

Next steps:
  ./verify-perf-gate.sh                  # run the Locust perf gate (expect PASS)
  ./verify-perf-gate.sh --fail-scenario  # force an impossible SLO (expect FAIL)
  ./teardown.sh                          # delete the cluster when done
EOF
