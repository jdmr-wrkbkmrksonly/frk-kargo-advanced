# local-cicd: validating the Locust perf-gate locally

A disposable local environment for proving the `locust-perf-test` verification gate (see
`../kargo/analysis.yaml`, `../kargo/configmaps.yaml`, and the `perf-test` Stage in
`../kargo/stages.yaml`) actually works — Locust runs as a Job, hits `guestbook`, and its
pass/fail SLO check correctly flips the resulting AnalysisRun to `Successful`/`Failed`.

This is intentionally **minimal**: no Argo CD, no git server, no full Stage/Promotion/Freight
flow. It installs cert-manager + the Argo Rollouts CRDs + Kargo, applies this repo's `kargo/`
manifests unchanged, deploys `guestbook` straight via `kubectl` (bypassing Argo CD), and drives
the `locust-perf-test` AnalysisTemplate directly via a standalone `AnalysisRun` — the same object
Kargo's controller would create from the Stage's `verification` block during a real Promotion.

## Prerequisites

Confirmed available on this machine: `podman` (with a running `podman machine`), `kind`,
`kubectl`, `helm`, `jq`, `htpasswd`, `openssl`.

## Usage

```shell
cd local-cicd
./setup.sh                  # create the cluster and install everything
./verify-perf-gate.sh       # run the gate — expect PASS
./verify-perf-gate.sh --fail-scenario   # force an impossible p95 threshold — expect FAIL
./teardown.sh                # delete the cluster
```

`verify-perf-gate.sh` also accepts overrides via environment variables (defaults match the
`perf-test` Stage's own `verification.args`):

```shell
HOST=http://guestbook.guestbook-perf-test.svc.cluster.local \
USERS=20 SPAWN_RATE=5 RUN_TIME=1m MAX_FAIL_RATIO=0.01 MAX_P95_MS=500 \
  ./verify-perf-gate.sh
```

## Troubleshooting

- **Pods stuck `Pending`**: the default Podman machine has 4GiB RAM, which can be tight for
  cert-manager + Argo Rollouts + Kargo + guestbook + a Locust Job all at once. Bump it:
  ```shell
  podman machine stop
  podman machine set --memory 6144
  podman machine start
  podman machine list
  ```
- **`kind create cluster` fails to reach the Podman socket**: make sure `podman machine list`
  shows a machine `Currently running` before running `./setup.sh`.
- **`ERROR: failed to create cluster: node(s) already exist for a cluster with the name "..."`**:
  `kind get clusters` is broken with this `kind`/`podman` version combo (podman's `ps --format`
  renders `.Labels` as a string, but kind's template does `index .Labels "..."` expecting a map,
  failing with `cannot index slice/array with type string`). `setup.sh` now detects an existing
  cluster via `kubectl` instead and cleans up stale node containers via `podman` directly before
  creating, so this should self-heal on re-run. If it still happens, manually clear leftovers:
  `podman rm -f kargo-advanced-local-control-plane`, then re-run `./setup.sh`.
- **Re-running `verify-perf-gate.sh`**: each run creates a uniquely-named `AnalysisRun`
  (`locust-perf-test-manual-<timestamp>`) and deletes it on exit, so repeated runs don't collide.
- **`metadata.annotations: Too long: may not be more than 262144 bytes` while installing
  cert-manager/Argo Rollouts**: their CRDs embed large OpenAPI schemas that overflow the
  `kubectl.kubernetes.io/last-applied-configuration` annotation a normal `kubectl apply` writes.
  `setup.sh` already installs both via `kubectl apply --server-side --force-conflicts`, which
  avoids that annotation entirely — if you still hit this, make sure you're on the latest
  `setup.sh` and re-run it (safe to re-run; it reuses the existing cluster).
