# Priority and preemption

## The problem

Gang scheduling decides whether a job can start. It does not decide which job goes first when GPUs are scarce. Without priorities, every Pod has priority 0:

- **First come, first served.** Pending jobs are tried in arrival order, so an urgent job waits behind whatever was submitted before it.
- **Starvation.** A long-running, low-value job can hold GPUs indefinitely. An important job that arrives later cannot start until it finishes, however long that takes.
- **Half-evicted gangs.** If a scheduler frees GPUs by evicting Pods one at a time, it can evict part of a distributed job. The Pods left behind keep their GPUs but can do no useful work without the rest.

PriorityClasses give jobs an order. Workload-aware preemption in v1.37 lets a high-priority gang evict lower-priority work to make room, and lets a gang declare that it must be evicted as a whole.

## How it works in Kubernetes v1.37

Sources: the Kubernetes docs on [Pod priority and preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/), [workload-aware preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/workload-aware-preemption/), [disruption and priority in the Workload API](https://kubernetes.io/docs/concepts/workloads/workload-api/disruption-and-priority/), and the [v1.37 workload-aware scheduling blog post](https://kubernetes.io/blog/2026/09/08/kubernetes-v1-37-advancing-workload-aware-scheduling/). Every field below was confirmed with `kubectl explain` on the running v1.37.0 cluster.

- **PriorityClass** (`scheduling.k8s.io/v1`, GA): maps a name to an integer `value`. Higher values are more important. [`manifests/priority/priorityclasses.yaml`](../manifests/priority/priorityclasses.yaml) defines `gpu-high` (1000) and `gpu-low` (100). Both have `globalDefault: false`, so Pods that do not name a class keep priority 0, and both keep the default `preemptionPolicy: PreemptLowerPriority`.
- **PodGroup priority.** `spec.priorityClassName` on a PodGroup (and on a Workload's `podGroupTemplates[]`) is resolved by the priority admission controller into `spec.priority`, the same way as for Pods. Each Pod of the group sets the same `priorityClassName`, because a Pod's priority must equal its PodGroup's.
- **Queue order.** The scheduling queue orders pending PodGroups by their priority, so a higher-priority gang is tried before a lower-priority one that has been waiting longer.
- **Workload-aware preemption.** When a PodGroup cannot be placed, the scheduler looks for victims among strictly lower-priority Pods and PodGroups across the cluster. It simulates removing all potential victims, finds one placement for the whole group, then reprieves as many victims as it can while that placement still fits. The docs note that this can miss a placement that needs fewer evictions.
- **Victim order.** Less important victims are chosen first: lower priority, then single Pods before PodGroups, then smaller groups, then the most recently started.
- **`spec.disruptionMode`** on a PodGroup (and Workload template): `single: {}` (the default) lets the scheduler evict individual Pods of the group; `all: {}` means the group is evicted together or not at all. The field is immutable. Both demo gangs use `all`.

### No new feature gate

In v1.37, workload-aware preemption is part of the existing `GenericWorkload` gate, which `kind-config.yaml` already enables. So `kind-config.yaml` and `scheduler-config.yaml` are unchanged. The separate alpha gate `PodGroupPreemptionPolicy` only adds a per-PodGroup `spec.preemptionPolicy` field (for example, a group that must never preempt others). This demo does not need that field, so the gate stays off.

## Manifests

All files are in [`manifests/priority/`](../manifests/priority/). Every Pod requests 2 GPUs, so each job needs 8 of the cluster's 12.

| File | Contents |
| --- | --- |
| [`priorityclasses.yaml`](../manifests/priority/priorityclasses.yaml) | `gpu-high` (1000) and `gpu-low` (100) |
| [`gang-high.yaml`](../manifests/priority/gang-high.yaml) | Workload `high-job`, PodGroup `high-job-workers` (`gpu-high`, `disruptionMode: all`, gang `minCount: 4`) and Pods `high-job-0..3` |
| [`gang-low.yaml`](../manifests/priority/gang-low.yaml) | The same at `gpu-low`: `low-job`, `low-job-workers`, `low-job-0..3` |
| [`plain-low.yaml`](../manifests/priority/plain-low.yaml) | Pods `low-plain-0..3` at `gpu-low` with no PodGroup |
| [`blocker.yaml`](../manifests/priority/blocker.yaml) | Pods `blocker-0..2`, 4 GPUs each (all 12), at `gpu-high` |

### Why the blocker runs at gpu-high

The queue-order demo needs something that holds every GPU while both gangs wait, so that their order is decided by the queue and not by preemption. Preemption only evicts strictly lower priority. A `gpu-low` or priority-0 blocker would simply be evicted by `high-job` as soon as it arrived, and the demo would show preemption instead of queue order. At `gpu-high`, the blocker has the same priority as `high-job`, so neither gang can evict it.

## Reproduce

Starting from the cluster described in the [README](../README.md), with fake GPUs from `scripts/setup-fake-gpus.sh`:

```bash
kubectl apply -f manifests/priority/priorityclasses.yaml

./scripts/priority-demo.sh queue-order
./scripts/priority-demo.sh preemption
```

[`scripts/priority-demo.sh`](../scripts/priority-demo.sh) runs these scenarios in `default`. Each one first removes objects left by the gang, topology and priority demos:

- **queue-order.** It creates the blocker and waits for it to be Ready. It then applies `gang-low.yaml`, waits 5 seconds and applies `gang-high.yaml`, so the low-priority gang has been waiting longer. Once scheduling settles, it deletes the blocker and reports again.
- **preemption.** It runs twice on an empty cluster. Each run places the low-priority workload (8 GPUs), then applies `gang-high.yaml`, which needs 8 GPUs while only 4 are free. The first run uses the `low-job` gang with `disruptionMode: all`, the second uses `low-plain` Pods without a PodGroup.

"Settled" means that Pod states, nodes and deletion timestamps have not changed for 10 seconds. The script waits at least 15 seconds and at most 120. The script records every Pod's UID when it is created, so it can still count evictions from the `Preempted` events after the Pods are gone. For each job, the report prints priority, Running, Pending, evicted Pods and GPUs held. It then prints the time each job had all its Pods scheduled (from `Scheduled` events), PodGroup status, and the scheduler's last message for the first Pending Pod.

## Results

Cluster: kind v0.33.0, `kindest/node:v1.37.0`, 1 control plane and 3 workers with 4 fake GPUs each, `GenericWorkload` and `TopologyAwareWorkloadScheduling` enabled, Kyverno and its policies installed (the demos run in `default`, which the policies do not match).

### Queue order

Output of `./scripts/priority-demo.sh queue-order`, with the blocker holding all 12 GPUs:

```text
JOB        PRIORITY         RUNNING PENDING EVICTED GPUS HELD
blocker    gpu-high (1000)        3       0       0        12
low-job    gpu-low (100)          0       4       0         0
high-job   gpu-high (1000)        0       4       0         0

PODGROUP           PRIORITY   DISRUPTION       CONDITION                    STATUS   REASON
high-job-workers   1000       map[all:map[]]   PodGroupInitiallyScheduled   False    Unschedulable
low-job-workers    100        map[all:map[]]   PodGroupInitiallyScheduled   False    Unschedulable
```

The scheduler's message for `high-job-0` was `0/4 nodes are available: 1 node(s) had untolerated taint(s), 3 Insufficient nvidia.com/gpu.` Neither gang preempted the equal-priority blocker.

After the blocker was deleted:

```text
JOB        PRIORITY         RUNNING PENDING EVICTED GPUS HELD
blocker    (all pods gone)        0       0       0         0
low-job    gpu-low (100)          0       4       0         0
high-job   gpu-high (1000)        4       0       0         8

Placement order (time the last Pod of each job was scheduled):
  1. blocker    2026-10-25T19:11:55Z  (3 Pods)
  2. high-job   2026-10-25T19:12:21Z  (4 Pods)
  -  low-job    not fully placed

PODGROUP           PRIORITY   DISRUPTION       CONDITION                    STATUS   REASON
high-job-workers   1000       map[all:map[]]   PodGroupInitiallyScheduled   True     Scheduled
low-job-workers    100        map[all:map[]]   PodGroupInitiallyScheduled   False    Unschedulable
```

`high-job` was placed first, although `low-job` had been waiting 5 seconds longer. That leaves 4 free GPUs, which is not enough for `low-job`'s 8, so it stays Pending and binds no Pods (gang scheduling). The scheduler's message for `low-job-0` ends with `minCount (4) cannot be satisfied: 2 scheduled, 1 remaining, ... pod group preemption: pod group is unschedulable`. It cannot preempt `high-job`, which has higher priority. The same result came out in all three runs.

### Preemption

Output of `./scripts/priority-demo.sh preemption`, first run, with `low-job` as a gang with `disruptionMode: all`:

```text
JOB        PRIORITY         RUNNING PENDING EVICTED GPUS HELD
low-job    (all pods gone)        0       0       4         0
high-job   gpu-high (1000)        4       0       0         8

Placement order (time the last Pod of each job was scheduled):
  1. low-job    2026-10-25T19:14:06Z  (4 Pods)
  2. high-job   2026-10-25T19:14:23Z  (4 Pods)

PODGROUP           PRIORITY   DISRUPTION       CONDITION                    STATUS   REASON
high-job-workers   1000       map[all:map[]]   PodGroupInitiallyScheduled   True     Scheduled
low-job-workers    100        map[all:map[]]   PodGroupInitiallyScheduled   True     Scheduled
```

Each of the 4 `low-job` Pods got a `Preempted` event with the message `Preempted by podgroup <high-job-workers UID> on node cluster`. Second run, with `low-plain` Pods without a PodGroup:

```text
JOB        PRIORITY         RUNNING PENDING EVICTED GPUS HELD
low-plain  (all pods gone)        0       0       4         0
high-job   gpu-high (1000)        4       0       0         8

Placement order (time the last Pod of each job was scheduled):
  1. low-plain  2026-10-25T19:14:39Z  (4 Pods)
  2. high-job   2026-10-25T19:14:56Z  (4 Pods)
```

Over repeated runs:

| Low-priority workload | Runs | Evicted | high-job |
| --- | --- | --- | --- |
| `low-job` gang, `disruptionMode: all` | 8 | 4 of 4 in every run | 4 Running, 8 GPUs, every run |
| `low-plain` Pods, no PodGroup | 8 | 2 of 4 in one run (the other 2 kept running with 4 GPUs), 4 of 4 in seven runs | 4 Running, 8 GPUs, every run |

`high-job` always started with all 4 Pods at once, as soon as the victims were gone. With `disruptionMode: all`, the low-priority gang was always evicted as a whole, so no Pods were left holding GPUs without the rest of their job.

### No regressions

With the PriorityClasses installed, on the same cluster:

| Check | Result |
| --- | --- |
| `./scripts/gang-demo.sh partial gang` | gpu-test 6 Running; trainer 0 Running, 4 Pending, 0 GPUs held; `trainer-workers` `PodGroupInitiallyScheduled=False` (`Unschedulable`) |
| `./scripts/topology-demo.sh with-topology` | all 4 trainer Pods in rack-1, `PodGroupInitiallyScheduled=True` |
| `./scripts/policy-demo.sh` | the same nine rows as in [policy enforcement](policy-enforcement.md) |
| `manifests/gpu-test.yaml` alone | 4 / 2 / 0 Pods per worker: packed, one worker left empty |

These match the earlier results. None of those demos set a `priorityClassName`, and neither PriorityClass is a global default, so their Pods keep priority 0.

## Differences from expectations

- **Plain Pods: 2 or 4 evictions.** Freeing 8 GPUs for `high-job` needs only 2 of the 4 `low-plain` Pods evicted, if they are the 2 on the same node. That happened in one run; the other seven evicted all 4. This is the documented trade-off of workload-aware preemption: it removes every potential victim, picks one placement for the whole group with the normal scoring, then reprieves only the victims that do not overlap that placement. In this cluster, the Kyverno Pods all run on one worker, so that worker has more CPU and memory requested than the others (500m CPU and 370Mi memory, against 100m and 50Mi on each of the other two). With GPUs simulated as free, `MostAllocated` scoring prefers that worker, and the other two score the same, so the second node is a tie-break. When the chosen pair of nodes covers both nodes holding `low-plain` Pods, none can be reprieved. The tie-break went that way in seven of eight runs. Why the split is so uneven has not been determined. The guaranteed difference is this: `disruptionMode: all` always evicts the whole gang, while plain Pods may be evicted individually, and how many go depends on the simulated placement.
- **Evicted gang still shows Scheduled.** After all its Pods were preempted, `low-job-workers` still had `PodGroupInitiallyScheduled=True`. The condition records that the group was placed once and is not reset by eviction. Pod counts and `Preempted` events are what show the eviction.
- **Starved gang under queue order.** After the blocker left, `low-job` did not start at all, because 4 free GPUs cannot hold its 8. This is gang scheduling working as intended: it waits for enough room instead of starting a partial job.
- **Cleanup in the other demos.** `scripts/gang-demo.sh` and `scripts/topology-demo.sh` now also delete objects labelled `app.kubernetes.io/part-of=priority-demo` before they run. Otherwise leftover `gpu-high` Pods could hold GPUs and change their results.
- **Which nodes are used varies.** Which workers the Pods land on, and which `low-plain` Pods are evicted, varies between runs because of tie-breaks between equally scored nodes. The counts above do not depend on it, except for the plain-Pods eviction count explained above.
