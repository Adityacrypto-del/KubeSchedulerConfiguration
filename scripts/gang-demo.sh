#!/usr/bin/env bash
# Gang scheduling demos for KubeSchedulerConfiguration, run against the
# sched-dev cluster created from kind-config.yaml (GenericWorkload enabled) with
# fake GPUs from setup-fake-gpus.sh.
#
# Usage:
#   ./scripts/gang-demo.sh partial  gang|no-gang
#       6-pod gpu-test Deployment (6 GPUs used, 6 free), then a 4-pod trainer
#       job that needs 8 GPUs.
#   ./scripts/gang-demo.sh deadlock gang|no-gang
#       Empty cluster (12 GPUs free), then job-a and job-b (8 GPUs each),
#       created interleaved.
#
# Each run first removes objects left by earlier demos.
set -euo pipefail

DEMO="${1:-}"
MODE="${2:-}"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
GANG_DIR="$REPO_ROOT/manifests/gang"
SELECTOR="app.kubernetes.io/part-of=gang-demo"

usage() {
  echo "usage: $0 partial|deadlock gang|no-gang" >&2
  exit 1
}

case "$DEMO/$MODE" in
  partial/no-gang) manifest="$GANG_DIR/trainer.yaml" ;;
  partial/gang) manifest="$GANG_DIR/trainer-gang.yaml" ;;
  deadlock/no-gang) manifest="$GANG_DIR/deadlock.yaml" ;;
  deadlock/gang) manifest="$GANG_DIR/deadlock-gang.yaml" ;;
  *) usage ;;
esac

echo "== Cleaning up previous demo objects"
kubectl delete pods -l "$SELECTOR" --ignore-not-found --wait=true
kubectl delete deployment gpu-test --ignore-not-found --wait=true
kubectl wait --for=delete pod -l app=gpu-test --timeout=60s 2>/dev/null || true
kubectl delete podgroups.scheduling.k8s.io,workloads.scheduling.k8s.io -l "$SELECTOR" --ignore-not-found --wait=true

if [[ "$DEMO" == "partial" ]]; then
  echo "== Filling 6 of 12 GPUs with manifests/gpu-test.yaml"
  kubectl apply -f "$REPO_ROOT/manifests/gpu-test.yaml"
  kubectl rollout status deployment/gpu-test --timeout=120s
fi

echo "== Applying $(basename "$manifest")"
kubectl apply -f "$manifest"

# Gang scheduling has no fixed timeout: a group that cannot reach minCount stays
# in the unschedulable queue. So wait until pod states stop changing.
snapshot() {
  kubectl get pods -l "$SELECTOR" --no-headers \
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
echo "== Result: $DEMO, $MODE"
jobs="trainer"
[[ "$DEMO" == "deadlock" ]] && jobs="job-a job-b"
[[ "$DEMO" == "partial" ]] && jobs="gpu-test $jobs"

for job in $jobs; do
  if [[ "$job" == "gpu-test" ]]; then sel="app=gpu-test"; else sel="job=$job"; fi
  # name phase node gpus; a pod with no node is reported as Pending.
  rows=$(kubectl get pods -l "$sel" --no-headers \
    -o custom-columns='N:.metadata.name,P:.status.phase,NODE:.spec.nodeName,G:.spec.containers[0].resources.limits.nvidia\.com/gpu' |
    sort | awk '{ if ($3 == "<none>") $2 = "Pending"; print }')
  running=$(awk '$2 == "Running"' <<<"$rows" | wc -l | tr -d ' ')
  pending=$(awk '$2 == "Pending"' <<<"$rows" | wc -l | tr -d ' ')
  gpus=$(awk '$3 != "<none>" { s += $4 } END { print s + 0 }' <<<"$rows")
  echo "$job: Running=$running Pending=$pending GPUs held=$gpus"
  awk '{ node = ($3 == "<none>") ? "-" : $3; printf "  %-26s %-8s %s\n", $1, $2, node }' <<<"$rows"
done

if [[ "$MODE" == "gang" ]]; then
  echo
  echo "== PodGroup status"
  kubectl get podgroups.scheduling.k8s.io -l "$SELECTOR" \
    -o custom-columns='PODGROUP:.metadata.name,MINCOUNT:.spec.schedulingPolicy.gang.minCount,CONDITION:.status.conditions[*].type,STATUS:.status.conditions[*].status,REASON:.status.conditions[*].reason'
fi

first_pending=$(kubectl get pods -l "$SELECTOR" --no-headers -o custom-columns='N:.metadata.name,NODE:.spec.nodeName' |
  awk '$2 == "<none>" { print $1; exit }')
if [[ -n "$first_pending" ]]; then
  echo
  echo "== Scheduler reason for $first_pending"
  kubectl get events --field-selector "involvedObject.name=$first_pending,reason=FailedScheduling" \
    --sort-by=.lastTimestamp -o custom-columns='MESSAGE:.message' --no-headers | tail -1
fi
