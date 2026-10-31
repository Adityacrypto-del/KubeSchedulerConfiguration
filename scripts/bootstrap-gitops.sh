#!/usr/bin/env bash
# Bootstrap GitOps for KubeSchedulerConfiguration: install Argo CD, apply the
# root Application, and wait until Argo CD has synced Kyverno, the policies and
# the platform objects from the main branch on GitHub. Safe to re-run.
#
# Works on a fresh cluster and on one where Kyverno, the policies, the
# PriorityClasses and the ml-team-a namespace were installed by hand: Argo CD
# adopts the existing objects in place (see docs/gitops.md).
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
APPS=(root kyverno platform policies)

"$REPO_ROOT/scripts/install-argocd.sh"

echo "== Applying the root Application"
kubectl apply -f "$REPO_ROOT/gitops/root.yaml"

echo "== Waiting for the Applications to be Synced and Healthy"
deadline=$((SECONDS + 600))
for app in "${APPS[@]}"; do
  until [[ "$(kubectl -n argocd get application "$app" \
      -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)" == "Synced/Healthy" ]]; do
    if (( SECONDS > deadline )); then
      echo "timed out waiting for Application $app" >&2
      kubectl -n argocd get applications >&2
      exit 1
    fi
    sleep 5
  done
done
kubectl -n argocd get applications

# If Kyverno was installed by scripts/install-kyverno.sh before GitOps, Helm's
# release record is still there. Argo CD now owns the objects, so remove the
# record to leave one owner and keep `helm upgrade` from fighting Argo CD.
if kubectl -n kyverno get secret -l owner=helm,name=kyverno -o name 2>/dev/null | grep -q .; then
  echo "== Removing the old Helm release record for Kyverno (the objects stay)"
  kubectl -n kyverno delete secret -l owner=helm,name=kyverno
fi

echo "== Kyverno policies"
kubectl get clusterpolicy 2>/dev/null
