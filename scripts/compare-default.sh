#!/usr/bin/env bash
# Comparison for KubeSchedulerConfiguration: recreates the sched-dev cluster,
# adds the same fake GPUs, applies the same 6-pod test Deployment and prints how
# many pods land on each worker. It then submits a single 4-GPU pod and reports
# whether it can be scheduled.
#
# Usage:
#   ./scripts/compare-default.sh          # stock kube-scheduler configuration (baseline)
#   ./scripts/compare-default.sh custom   # this repository's scheduler-config.yaml
#
# Run "custom" last to leave the custom-config cluster running.
set -euo pipefail

MODE="${1:-default}"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
CLUSTER=sched-dev
IMAGE=kindest/node:v1.37.0

kind delete cluster --name "$CLUSTER"
case "$MODE" in
  default)
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
    ;;
  custom)
    kind create cluster --name "$CLUSTER" --wait 120s --config "$REPO_ROOT/kind-config.yaml"
    ;;
  *)
    echo "usage: $0 [default|custom]" >&2
    exit 1
    ;;
esac

kubectl wait --for=condition=Ready nodes --all --timeout=120s
kubectl -n kube-system wait --for=condition=Ready pod -l component=kube-scheduler --timeout=60s
"$REPO_ROOT/scripts/setup-fake-gpus.sh"

kubectl apply -f "$REPO_ROOT/manifests/gpu-test.yaml"
kubectl rollout status deployment/gpu-test --timeout=120s

echo
echo "Placement with the ${MODE} scheduler configuration:"
for node in "${CLUSTER}-worker" "${CLUSTER}-worker2" "${CLUSTER}-worker3"; do
  count=$(kubectl get pods -l app=gpu-test --field-selector "spec.nodeName=${node}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "  ${node}: ${count}"
done

echo
kubectl apply -f "$REPO_ROOT/manifests/gpu-large-job.yaml"
kubectl wait --for=condition=Ready pod/gpu-large-job --timeout=30s >/dev/null 2>&1 || true

phase=$(kubectl get pod gpu-large-job -o jsonpath='{.status.phase}')
echo "4-GPU pod gpu-large-job: ${phase}"
if [[ "$phase" == "Running" ]]; then
  echo "  node: $(kubectl get pod gpu-large-job -o jsonpath='{.spec.nodeName}')"
else
  echo "  scheduler reason:"
  kubectl describe pod gpu-large-job | sed -n '/^Events:/,$p' | grep FailedScheduling | sed 's/^/    /'
fi
