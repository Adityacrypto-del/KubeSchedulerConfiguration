#!/usr/bin/env bash
# Topology-aware placement demo for KubeSchedulerConfiguration, run against the
# sched-dev cluster created from kind-config.yaml (GenericWorkload and
# TopologyAwareWorkloadScheduling enabled) with fake GPUs from setup-fake-gpus.sh.
#
# Usage:
#   ./scripts/topology-demo.sh without-topology   # gang job, bin-packing only
#   ./scripts/topology-demo.sh with-topology      # same job, constrained to one topology.rack
#
# Filler pods first leave 1 free GPU on sched-dev-worker (rack-1), 4 on
# sched-dev-worker2 (rack-1) and 2 on sched-dev-worker3 (rack-2). Then a 4-pod
# job needing 1 GPU per pod is applied. Each run first removes objects left by
# earlier demos.
set -euo pipefail

MODE="${1:-}"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
TOPO_DIR="$REPO_ROOT/manifests/topology"
SELECTOR="app.kubernetes.io/part-of=topology-demo"

case "$MODE" in
  without-topology) manifest="$TOPO_DIR/trainer.yaml" ;;
  with-topology) manifest="$TOPO_DIR/trainer-topology.yaml" ;;
  *)
    echo "usage: $0 with-topology|without-topology" >&2
    exit 1
    ;;
esac

echo "== Cleaning up previous demo objects"
for sel in "$SELECTOR" "app.kubernetes.io/part-of=gang-demo"; do
  kubectl delete pods -l "$sel" --ignore-not-found --wait=true
  kubectl delete podgroups.scheduling.k8s.io,workloads.scheduling.k8s.io -l "$sel" --ignore-not-found --wait=true
done
kubectl delete deployment gpu-test --ignore-not-found --wait=true
kubectl delete pod gpu-large-job --ignore-not-found --wait=true
kubectl wait --for=delete pod -l app=gpu-test --timeout=60s 2>/dev/null || true

echo "== Placing filler pods"
kubectl apply -f "$TOPO_DIR/fillers.yaml"
kubectl wait --for=condition=Ready pod -l "$SELECTOR,job=filler" --timeout=60s

echo "== Free GPUs before the job"
for node in sched-dev-worker sched-dev-worker2 sched-dev-worker3; do
  rack=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.topology\.rack}')
  alloc=$(kubectl get node "$node" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  used=$(kubectl get pods -A --field-selector "spec.nodeName=$node" --no-headers \
    -o custom-columns='G:.spec.containers[*].resources.limits.nvidia\.com/gpu' |
    awk '$1 != "<none>" { s += $1 } END { print s + 0 }')
  echo "  $node ($rack): $((alloc - used)) free"
done

echo "== Applying $(basename "$manifest")"
kubectl apply -f "$manifest"

# Wait until pod states stop changing (gang scheduling has no fixed timeout).
snapshot() {
  kubectl get pods -l "$SELECTOR,job=trainer" --no-headers \
    -o custom-columns='N:.metadata.name,P:.status.phase,NODE:.spec.nodeName' 2>/dev/null
}
echo "== Waiting for scheduling to settle (unchanged for 10s, at least 15s, at most 120s)"
start=$(date +%s)
last=""
stable_since=$start
while true; do
  now=$(date +%s)
  current=$(snapshot)
  if [[ "$current" != "$last" ]]; then
    last="$current"
    stable_since=$now
  fi
  if (( now - start >= 15 && now - stable_since >= 10 )); then break; fi
  if (( now - start >= 120 )); then echo "   (still changing after 120s)"; break; fi
  sleep 2
done

echo
echo "== Result: $MODE"
racks=""
while read -r name phase node; do
  if [[ "$node" == "<none>" ]]; then
    printf "  %-10s %-8s %-18s %s\n" "$name" "Pending" "-" "-"
  else
    rack=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.topology\.rack}')
    racks="$racks $rack"
    printf "  %-10s %-8s %-18s %s\n" "$name" "$phase" "$node" "$rack"
  fi
done < <(snapshot | sort)

bound=$(wc -w <<<"$racks" | tr -d ' ')
distinct=$(tr ' ' '\n' <<<"$racks" | sed '/^$/d' | sort -u | tr '\n' ' ')
if (( bound == 0 )); then
  echo "Job placement: no pods bound"
elif [[ $(wc -w <<<"$distinct") -eq 1 ]]; then
  echo "Job placement: one rack (${distinct% }), $bound of 4 pods bound"
else
  echo "Job placement: split across racks (${distinct% }), $bound of 4 pods bound"
fi

echo
echo "== PodGroup status"
kubectl get podgroups.scheduling.k8s.io -l "$SELECTOR" \
  -o custom-columns='PODGROUP:.metadata.name,TOPOLOGY:.spec.schedulingConstraints.topology[*].key,CONDITION:.status.conditions[*].type,STATUS:.status.conditions[*].status,REASON:.status.conditions[*].reason'
