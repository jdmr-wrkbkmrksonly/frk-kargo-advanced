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
USERS=20 SPAWN_RATE=5 RUN_TIME=1m ENFORCE_SLO=true \
  ./verify-perf-gate.sh
```

Note: per-endpoint thresholds (latency, RPS, error rate) now live in `env/perf-test/config.yaml`,
not in args/env vars — edit that file to change what's actually being gated on. `ENFORCE_SLO=false`
is a global override that makes the whole run advisory-only regardless of what `config.yaml` says.

## Viewing AnalysisRun logs

The Kargo UI's "AnalysisRun log streaming is not configured" message is expected here — that
feature requires an external, HTTP-fetchable log backend (Loki, etc.) that we don't run on this
disposable cluster. Use `show-analysisrun-logs.sh` instead:

```shell
./show-analysisrun-logs.sh                # most recently created AnalysisRun
./show-analysisrun-logs.sh <run-name>      # a specific one
```

## Promoting real Freight through the Kargo UI/CLI (optional)

Beyond `verify-perf-gate.sh`, you can also drive a real Promotion through `dev` → `staging` →
`perf-test` from the Kargo UI/CLI. Two things to set up first, since this cluster has no Argo CD:

1. **Git credentials**, so the `git-push` step can authenticate against your fork:
   ```shell
   kargo create repo-credentials github-creds \
     --project=kargo-advanced \
     --git \
     --repo-url=<your fork's .git URL> \
     --username=<your github username>
     # omit --password so it prompts interactively instead of landing in shell history
   ```
2. **Strip `argocd-update` from the `promote` PromotionTask** — `setup.sh` already runs this for
   you (via `disable-argocd-update.sh`), but it needs re-running every time your fork's
   `kargo/promotiontasks.yaml` gets re-applied (which restores `argocd-update` and will start
   failing promotions again, since there's no real Argo CD here to satisfy it). Use `sync-fork.sh`
   after every `git push` instead of remembering both steps:
   ```shell
   ./sync-fork.sh   # kubectl apply -f <fork>/kargo, then re-run disable-argocd-update.sh
   ```
   Defaults to `FORK_DIR=/Users/jose.morales/Workspaces/Prsnl/ArgoCDProjects/kargo/frk-kargo-advanced`;
   override with `FORK_DIR=/path/to/your/fork ./sync-fork.sh` if that ever changes. This — like
   `disable-argocd-update.sh` — only patches the live cluster; it never touches any committed
   `kargo/promotiontasks.yaml`, so production (which needs `argocd-update`) is unaffected.

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
