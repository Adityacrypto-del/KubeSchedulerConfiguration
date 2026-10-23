#!/usr/bin/env bash
# Baseline for KubeSchedulerConfiguration: recreates the sched-dev cluster with
# the stock kube-scheduler configuration (same 3 workers, no scheduler-config.yaml),
# adds the same fake GPUs, applies the same test Deployment and prints how many
# pods land on each worker.
#
# This replaces the custom-config cluster. To go back to it afterwards:
#   kind delete cluster --name sched-dev
#   kind create cluster --name sched-dev --config kind-config.yaml
#   ./scripts/setup-fake-gpus.sh
#   kubectl apply -f manifests/gpu-test.yaml
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
CLUSTER=sched-dev
IMAGE=kindest/node:v1.37.0

kind delete cluster --name "$CLUSTER"
kind create cluster --name "$CLUSTER" --wait 120s --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    image: ${IMAGE}
  - role: worker
    image: ${IMAGE}
  - role: worker
    image: ${IMAGE}
  - role: worker
    image: ${IMAGE}
EOF

kubectl wait --for=condition=Ready nodes --all --timeout=120s
"$REPO_ROOT/scripts/setup-fake-gpus.sh"

kubectl apply -f "$REPO_ROOT/manifests/gpu-test.yaml"
kubectl rollout status deployment/gpu-test --timeout=120s

echo
echo "Placement with the default scheduler configuration:"
for node in "${CLUSTER}-worker" "${CLUSTER}-worker2" "${CLUSTER}-worker3"; do
  count=$(kubectl get pods -l app=gpu-test --field-selector "spec.nodeName=${node}" --no-headers | wc -l | tr -d ' ')
  echo "  ${node}: ${count}"
done
