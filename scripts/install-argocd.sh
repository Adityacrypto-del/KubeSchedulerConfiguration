#!/usr/bin/env bash
# Install or upgrade Argo CD for KubeSchedulerConfiguration with the pinned chart
# version and deploy/argocd/values.yaml, then wait until it is ready.
# Safe to re-run.
set -euo pipefail

CHART_VERSION="10.11.6"   # Argo CD v3.5.6
NAMESPACE="argocd"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo update argo >/dev/null

echo "== Installing or upgrading Argo CD chart $CHART_VERSION"
helm upgrade --install argocd argo/argo-cd \
  --namespace "$NAMESPACE" --create-namespace \
  --version "$CHART_VERSION" \
  --values "$REPO_ROOT/deploy/argocd/values.yaml" \
  --wait --timeout 5m

echo "== Waiting for Argo CD deployments and the application controller"
kubectl -n "$NAMESPACE" rollout status deployment --timeout=180s
kubectl -n "$NAMESPACE" rollout status statefulset argocd-application-controller --timeout=180s

echo "== Argo CD pods"
kubectl -n "$NAMESPACE" get pods
