#!/usr/bin/env bash
# Priority and preemption demos for KubeSchedulerConfiguration, run against the
# sched-dev cluster created from kind-config.yaml (GenericWorkload enabled) with
# fake GPUs from setup-fake-gpus.sh and the PriorityClasses from
# manifests/priority/priorityclasses.yaml.
#
# Usage:
#   ./scripts/priority-demo.sh queue-order
#       A gpu-high blocker holds all 12 GPUs. A gpu-low gang, then a gpu-high
#       gang (8 GPUs each) are created and wait. The blocker is deleted.
#   ./scripts/priority-demo.sh preemption
#       Empty cluster. A gpu-low workload holding 8 GPUs, then a gpu-high gang
#       needing 8. Run twice: low workload as a gang with disruptionMode all,
#       then as plain Pods without a PodGroup.
#
# Each scenario first removes objects left by earlier demos.
set -euo pipefail

DEMO="${1:-}"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
PRIO_DIR="$REPO_ROOT/manifests/priority"
SELECTOR="app.kubernetes.io/part-of=priority-demo"
UIDS="$(mktemp)"
trap 'rm -f "$UIDS"' EXIT

case "$DEMO" in
  queue-order|preemption) ;;
  *) echo "usage: $0 queue-order|preemption" >&2; exit 1 ;;
esac

cleanup() {
  echo "== Cleaning up previous demo objects"
  for sel in "$SELECTOR" "app.kubernetes.io/part-of=gang-demo" "app.kubernetes.io/part-of=topology-demo"; do
    kubectl delete pods -l "$sel" --ignore-not-found --wait=true
    kubectl delete podgroups.scheduling.k8s.io,workloads.scheduling.k8s.io -l "$sel" --ignore-not-found --wait=true
  done
  kubectl delete deployment gpu-test --ignore-not-found --wait=true
  kubectl delete pod gpu-large-job --ignore-not-found --wait=true
  kubectl wait --for=delete pod -l app=gpu-test --timeout=60s 2>/dev/null || true
  : > "$UIDS"
}

# apply FILE: create the objects and remember each Pod's UID, so evictions can
# be counted from events after the Pods are gone.
apply() {
  echo "== Applying $(basename "$1")"
  kubectl apply -f "$1"
  kubectl get -f "$1" --no-headers \
    -o custom-columns='KIND:.kind,UID:.metadata.uid,JOB:.metadata.labels.job' 2>/dev/null |
    awk '$1 == "Pod" { print $2, $3 }' >> "$UIDS"
}

# Gang scheduling has no fixed timeout and preemption takes a grace period, so
# wait until pod states stop changing.
settle() {
  local start now last="" current stable_since
  echo "== Waiting for scheduling to settle (unchanged for 10s, at least 15s, at most 120s)"
  start=$(date +%s)
  stable_since=$start
  while true; do
    now=$(date +%s)
    current=$(kubectl get pods -l "$SELECTOR" --no-headers \
      -o custom-columns='N:.metadata.name,P:.status.phase,NODE:.spec.nodeName,DEL:.metadata.deletionTimestamp' 2>/dev/null)
    if [[ "$current" != "$last" ]]; then
      last="$current"
      stable_since=$now
    fi
    if (( now - start >= 15 && now - stable_since >= 10 )); then break; fi
    if (( now - start >= 120 )); then echo "   (still changing after 120s)"; break; fi
    sleep 2
  done
}

# report TITLE: per job priority, Running, Pending, evicted, GPUs held, and the
# time each job had all of its Pods placed (from the scheduler's events).
report() {
  echo
  echo "== Result: $1"
  python3 - "$UIDS" <<'EOF'
import json, subprocess, sys

def kget(*args):
    return json.loads(subprocess.check_output(["kubectl", "get", *args, "-o", "json"]))["items"]

recorded = {}            # uid -> job
for line in open(sys.argv[1]):
    uid, job = line.split()
    recorded[uid] = job
jobs = list(dict.fromkeys(recorded.values()))

pods = {p["metadata"]["uid"]: p for p in kget("pods", "-l", "app.kubernetes.io/part-of=priority-demo")}
events = kget("events")
def when(e):
    return e.get("eventTime") or e.get("firstTimestamp") or e.get("lastTimestamp") or ""
scheduled, preempted = {}, {}
for e in events:
    uid = e["involvedObject"].get("uid")
    if uid not in recorded:
        continue
    if e["reason"] == "Scheduled":
        scheduled[uid] = when(e)
    elif e["reason"] == "Preempted":
        preempted[uid] = e["message"]

rows, placed = [], []
for job in jobs:
    uids = [u for u, j in recorded.items() if j == job]
    live = [pods[u] for u in uids if u in pods and not pods[u]["metadata"].get("deletionTimestamp")]
    running = sum(1 for p in live if p["status"].get("phase") == "Running")
    pending = sum(1 for p in live if not p["spec"].get("nodeName"))
    evicted = sum(1 for u in uids if u in preempted)
    gpus = sum(int(c["resources"].get("limits", {}).get("nvidia.com/gpu", 0))
               for p in live if p["spec"].get("nodeName") for c in p["spec"]["containers"])
    prio = next((pods[u]["spec"].get("priority") for u in uids if u in pods), None)
    cls = next((pods[u]["spec"].get("priorityClassName") for u in uids if u in pods), None)
    prio_txt = f"{cls} ({prio})" if cls else "(all pods gone)"
    rows.append((job, prio_txt, running, pending, evicted, gpus))
    times = [scheduled[u] for u in uids if u in scheduled]
    if len(times) == len(uids):
        placed.append((max(times), job, len(times)))

print(f"{'JOB':<10} {'PRIORITY':<16} {'RUNNING':>7} {'PENDING':>7} {'EVICTED':>7} {'GPUS HELD':>9}")
for r in rows:
    print(f"{r[0]:<10} {r[1]:<16} {r[2]:>7} {r[3]:>7} {r[4]:>7} {r[5]:>9}")
print()
print("Placement order (time the last Pod of each job was scheduled):")
if not placed:
    print("  no job had all of its Pods scheduled")
for i, (t, job, n) in enumerate(sorted(placed), 1):
    print(f"  {i}. {job:<10} {t}  ({n} Pods)")
for job in jobs:
    if not any(j == job for _, j, _ in placed):
        print(f"  -  {job:<10} not fully placed")
if preempted:
    print()
    print("Preempted events:")
    for u, msg in preempted.items():
        print(f"  {recorded[u]}: {msg}")
EOF
  local groups
  groups=$(kubectl get podgroups.scheduling.k8s.io -l "$SELECTOR" --no-headers -o name 2>/dev/null)
  if [[ -n "$groups" ]]; then
    echo
    echo "== PodGroup status"
    kubectl get podgroups.scheduling.k8s.io -l "$SELECTOR" \
      -o custom-columns='PODGROUP:.metadata.name,PRIORITY:.spec.priority,DISRUPTION:.spec.disruptionMode,CONDITION:.status.conditions[*].type,STATUS:.status.conditions[*].status,REASON:.status.conditions[*].reason'
  fi
  local first_pending
  first_pending=$(kubectl get pods -l "$SELECTOR" --no-headers -o custom-columns='N:.metadata.name,NODE:.spec.nodeName' |
    awk '$2 == "<none>" { print $1; exit }')
  if [[ -n "$first_pending" ]]; then
    echo
    echo "== Scheduler reason for $first_pending"
    kubectl get events --field-selector "involvedObject.name=$first_pending,reason=FailedScheduling" \
      --sort-by=.lastTimestamp -o custom-columns='MESSAGE:.message' --no-headers | tail -1
  fi
}

if [[ "$DEMO" == "queue-order" ]]; then
  cleanup
  apply "$PRIO_DIR/blocker.yaml"
  kubectl wait --for=condition=Ready pod -l job=blocker --timeout=120s
  apply "$PRIO_DIR/gang-low.yaml"
  sleep 5
  apply "$PRIO_DIR/gang-high.yaml"
  settle
  report "queue-order, blocker holding all 12 GPUs"
  echo
  echo "== Deleting the blocker"
  kubectl delete pods -l job=blocker --wait=false
  settle
  report "queue-order, after the blocker was deleted"
else
  cleanup
  apply "$PRIO_DIR/gang-low.yaml"
  settle
  apply "$PRIO_DIR/gang-high.yaml"
  settle
  report "preemption, low-priority gang with disruptionMode all"

  echo
  cleanup
  apply "$PRIO_DIR/plain-low.yaml"
  settle
  apply "$PRIO_DIR/gang-high.yaml"
  settle
  report "preemption, low-priority plain Pods without a PodGroup"
fi
