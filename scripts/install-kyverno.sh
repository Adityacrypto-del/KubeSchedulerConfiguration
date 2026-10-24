#!/usr/bin/env bash
# Install or upgrade Kyverno for KubeSchedulerConfiguration with the pinned chart
# version and deploy/kyverno/values.yaml, then wait until it is ready.
# Safe to re-run.
set -euo pipefail

CHART_VERSION="3.9.2"   # Kyverno v1.19.2
NAMESPACE="kyverno"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update >/dev/null
helm repo update kyverno >/dev/null

echo "== Installing or upgrading Kyverno chart $CHART_VERSION"
helm upgrade --install kyverno kyverno/kyverno \
  --namespace "$NAMESPACE" --create-namespace \
  --version "$CHART_VERSION" \
  --values "$REPO_ROOT/deploy/kyverno/values.yaml" \
  --wait --timeout 5m

echo "== Waiting for Kyverno deployments"
kubectl -n "$NAMESPACE" rollout status deployment --timeout=180s

echo "== Kyverno pods"
kubectl -n "$NAMESPACE" get pods
