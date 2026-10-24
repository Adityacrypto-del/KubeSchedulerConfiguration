# Topology-aware placement

## The problem

The Pods of a distributed GPU job exchange data constantly, for example gradients in every training step. Traffic between nodes in the same rack is faster and cheaper than traffic that crosses racks, so a job split across racks runs at the speed of its slowest link.

The scheduler does not know this on its own. GPU bin-packing in KubeSchedulerConfiguration places each Pod on the busiest node that still fits, which is the right choice for fragmentation but takes no account of where the job's other Pods are. With an uneven free-GPU pattern, one job can end up in several racks.

The goal: all Pods of one multi-Pod GPU job land in the same rack (node label `topology.rack`), while bin-packing and gang scheduling keep working.

## Mechanism

### Choice: native topology-aware workload scheduling

Kubernetes v1.37 can constrain a PodGroup to a single topology domain. A PodGroup, or the Workload `podGroupTemplates` entry it comes from, sets:

```yaml
schedulingConstraints:
  topology:
    - key: topology.rack
```

The scheduler then places all Pods of the group onto nodes that share one value of that node label. With a `gang` policy, it simulates placing the whole group inside each candidate domain, picks a feasible one, and binds the Pods there. If no single domain can fit `minCount` Pods, it binds none.

This was chosen over pod affinity because it decides the rack for the group as a whole. With `podAffinity` on `topology.rack`, the first Pod is placed by the normal scoring and every later Pod must follow it, even if that rack cannot fit the rest of the job. Native topology scheduling checks that the whole group fits in a rack before committing to it.

Sources: [Workload API](https://kubernetes.io/docs/concepts/workloads/workload-api/), [Topology-aware workload scheduling](https://kubernetes.io/docs/concepts/workloads/workload-api/topology-aware-scheduling/) and [PodGroup scheduling](https://kubernetes.io/docs/concepts/scheduling-eviction/podgroup-scheduling/). Fields confirmed with `kubectl explain` on the running cluster:

- `podgroup.spec.schedulingConstraints.topology[].key`: the docs say "only a single topology constraint can be specified".
- `workload.spec.podGroupTemplates[].schedulingConstraints.topology[].key`: the same, on the template.

`kubectl explain` notes that the field "is only available when the TopologyAwareWorkloadScheduling feature gate is enabled".

### Feature gate added

[`kind-config.yaml`](../kind-config.yaml) now enables a second gate:

```yaml
featureGates:
  GenericWorkload: true
  TopologyAwareWorkloadScheduling: true
```

`TopologyAwareWorkloadScheduling` is alpha (since v1.36) and off by default. kind passes it to every component, and the API server, controller manager and scheduler all run with `--feature-gates=GenericWorkload=true,TopologyAwareWorkloadScheduling=true`.

[`scheduler-config.yaml`](../scheduler-config.yaml) did not change. With the gate on, the scheduler's live configuration (from its `/configz` endpoint) lists two new plugins in its default set, `TopologyPlacementGenerator` and `PodGroupPodsCount`, next to `GangScheduling` and the `MostAllocated` bin-packing settings.

The gate also switches gang PodGroups to the placement-based scheduling algorithm. A group without a topology constraint gets one candidate placement covering the whole cluster. This shows up in the scheduler's messages: before the gate, a stuck gang reported `minCount (4) cannot be satisfied: 3 scheduled, 0 remaining`; with it, the message is `0/1 placements are available, first placement status: minCount (4) cannot be satisfied: 3 scheduled, 0 remaining`. The scheduling outcome is the same.

## Demo scenario

The cluster has two racks of unequal size: `sched-dev-worker` and `sched-dev-worker2` are `rack-1` (8 GPUs), and `sched-dev-worker3` is `rack-2` (4 GPUs). [`manifests/topology/fillers.yaml`](../manifests/topology/fillers.yaml) pins two filler Pods with `nodeSelector` to create this free-GPU pattern:

| Worker | Rack | GPUs used by filler | Free |
| --- | --- | --- | --- |
| sched-dev-worker | rack-1 | 3 | 1 |
| sched-dev-worker2 | rack-1 | 0 | 4 |
| sched-dev-worker3 | rack-2 | 2 | 2 |

The job is 4 Pods of 1 GPU each, gated by a Workload and PodGroup with `gang.minCount: 4`. Both modes use the same gang job; the only difference is the topology constraint:

| File | Contents |
| --- | --- |
| [`trainer.yaml`](../manifests/topology/trainer.yaml) | Without topology: Workload `trainer`, PodGroup `trainer-workers`, 4 Pods |
| [`trainer-topology.yaml`](../manifests/topology/trainer-topology.yaml) | With topology: the same, plus `schedulingConstraints.topology: [{key: topology.rack}]` on the template and the PodGroup |

Expected: bin-packing alone fills the busiest nodes first, sched-dev-worker (1 free), then sched-dev-worker3 (2 free), then sched-dev-worker2. That splits the job across both racks. With the rack constraint, rack-2 has only 2 free GPUs, so the only feasible domain for 4 Pods is rack-1.

## Reproduce

```bash
kind delete cluster --name sched-dev
kind create cluster --name sched-dev --config kind-config.yaml
./scripts/setup-fake-gpus.sh

./scripts/topology-demo.sh without-topology
./scripts/topology-demo.sh with-topology
```

[`scripts/topology-demo.sh`](../scripts/topology-demo.sh) removes objects from earlier demos (including the gang and bin-packing demos), places the fillers, prints free GPUs per worker, applies the job, and waits until Pod states have been unchanged for 10 seconds (at least 15, at most 120). It then prints each Pod's node and rack, whether the job ended up in one rack, and the PodGroup condition.

## Results

Cluster: kind v0.33.0, `kindest/node:v1.37.0`, 1 control plane and 3 workers with 4 fake GPUs each, `GenericWorkload` and `TopologyAwareWorkloadScheduling` enabled, scheduler running `scheduler-config.yaml`.

| Pod | Without topology | With topology |
| --- | --- | --- |
| trainer-0 | sched-dev-worker (rack-1) | sched-dev-worker (rack-1) |
| trainer-1 | sched-dev-worker3 (**rack-2**) | sched-dev-worker2 (rack-1) |
| trainer-2 | sched-dev-worker3 (**rack-2**) | sched-dev-worker2 (rack-1) |
| trainer-3 | sched-dev-worker2 (rack-1) | sched-dev-worker2 (rack-1) |
| Job placement | **split across rack-1 and rack-2** | **one rack (rack-1)** |
| PodGroup | `PodGroupInitiallyScheduled=True` | `PodGroupInitiallyScheduled=True` |

Without topology, the placement followed bin-packing exactly: the busiest node first, then the next busiest, splitting the job 2/2 across racks. With topology, the whole job stayed in rack-1. Bin-packing still applied inside the rack: the scheduler used the last free GPU on sched-dev-worker before moving to sched-dev-worker2.

### No regressions

After the gate was added, on the same cluster:

| Check | Result |
| --- | --- |
| `./scripts/gang-demo.sh partial gang` | trainer 0 Running, 4 Pending, 0 GPUs held (gpu-test 6 Running) |
| `./scripts/gang-demo.sh deadlock gang` | job-a 4 Running (8 GPUs), job-b 0 Running, 4 Pending |
| `manifests/gpu-test.yaml` alone | 2 / 0 / 4 Pods per worker: packed, one worker left empty |

### Differences from expectations

Both modes matched the expected placement. Two details:

- `scripts/gang-demo.sh` previously cleaned up only its own objects. It now also removes topology-demo objects, so leftover filler Pods cannot change its results.
- Gang PodGroups now go through the placement-based algorithm, which changes the wording of the scheduler's unschedulable message (see above) but not the outcome.
