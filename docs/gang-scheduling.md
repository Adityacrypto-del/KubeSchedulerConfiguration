# Gang scheduling

## The problem

The kube-scheduler places Pods one at a time. For a distributed job whose Pods only do useful work when all of them are running, that causes three problems:

- **Partial starts.** If the cluster has room for only some of a job's Pods, those Pods start anyway and wait for the rest.
- **Wasted GPUs.** The Pods that started hold their GPUs while doing nothing, and other work cannot use them.
- **Deadlock.** Two jobs that arrive together can each grab part of the cluster. Neither has enough to finish starting, and neither gives anything back.

Gang (all-or-nothing) scheduling fixes this: the Pods of a group are bound only if enough of them can be placed at the same time; otherwise none are.

## How it works in Kubernetes v1.37

KubeSchedulerConfiguration uses the native Workload and PodGroup APIs and the built-in `GangScheduling` scheduler plugin. There is no third-party scheduler and no custom code.

Sources: the Kubernetes docs on the [Workload API](https://kubernetes.io/docs/concepts/workloads/workload-api/), [PodGroup scheduling policies](https://kubernetes.io/docs/concepts/workloads/workload-api/policies/), the [PodGroup API](https://kubernetes.io/docs/concepts/workloads/podgroup-api/) and its [lifecycle](https://kubernetes.io/docs/concepts/workloads/podgroup-api/lifecycle/), [gang scheduling](https://kubernetes.io/docs/concepts/scheduling-eviction/gang-scheduling/), and the [v1.37 workload-aware scheduling blog post](https://kubernetes.io/blog/2026/09/08/kubernetes-v1-37-advancing-workload-aware-scheduling/). Every field below was confirmed with `kubectl explain` on the running v1.37.0 cluster.

- **Workload** (`scheduling.k8s.io/v1beta1`): a long-lived policy template. `spec.podGroupTemplates[]` holds named templates, each with a `schedulingPolicy` of `basic` or `gang`. For gang, `gang.minCount` is the number of Pods that must be placeable together.
- **PodGroup** (`scheduling.k8s.io/v1beta1`): the runtime instance the scheduler acts on. It carries its own `spec.schedulingPolicy.gang.minCount` and links back to its template with `spec.workloadRef.{workloadName, templateName}`.
- **Pod**: joins a group with `spec.schedulingGroup.podGroupName`. The field is immutable.

The `GangScheduling` plugin acts at two points:

1. **PreEnqueue.** A Pod in a PodGroup is held back until the PodGroup exists and at least `minCount` of its Pods have been created.
2. **Group scheduling cycle.** The scheduler then tries to place the group's Pods together. If at least `minCount` can be placed, they are bound. If not, none are bound and the Pods go to the unschedulable queue. When cluster state changes, for example when other Pods are deleted, the group is retried.

There is no fixed gang timeout in v1.37: none of the pages above describe one. A group that cannot reach `minCount` simply waits without holding resources. After the first scheduling decision, the scheduler records the result on the PodGroup as the `PodGroupInitiallyScheduled` condition. It does not update that condition afterwards.

## What changed in KubeSchedulerConfiguration

Only [`kind-config.yaml`](../kind-config.yaml) changed:

```yaml
featureGates:
  GenericWorkload: true
runtimeConfig:
  "scheduling.k8s.io/v1beta1": "true"
```

- `GenericWorkload` is beta and off by default in v1.37. It turns on the Workload and PodGroup APIs, gang scheduling and workload-aware preemption; the older `GangScheduling` and `WorkloadAwarePreemption` gates were merged into it. kind passes top-level `featureGates` to every component: kube-apiserver, kube-controller-manager, kube-scheduler and kubelet.
- Beta APIs are not served by default, so `runtimeConfig` enables the `scheduling.k8s.io/v1beta1` group on the API server.

[`scheduler-config.yaml`](../scheduler-config.yaml) did not need to change. Its explicit `NodeResourcesFit` score setting is merged with the default plugin set, and the scheduler's live configuration (read from its `/configz` endpoint) lists `GangScheduling` among the enabled plugins next to the `MostAllocated` bin-packing settings. A run of `manifests/gpu-test.yaml` on the gang-enabled cluster still packed the 6 Pods as 2/0/4.

## Reproduce

```bash
kind delete cluster --name sched-dev
kind create cluster --name sched-dev --config kind-config.yaml
./scripts/setup-fake-gpus.sh

kubectl api-resources | grep -i -E "workload|podgroup"   # Workload and PodGroup listed

./scripts/gang-demo.sh partial  no-gang
./scripts/gang-demo.sh partial  gang
./scripts/gang-demo.sh deadlock no-gang
./scripts/gang-demo.sh deadlock gang
```

[`scripts/gang-demo.sh`](../scripts/gang-demo.sh) removes objects from earlier demos, applies the manifests, waits until Pod states have been unchanged for 10 seconds (at least 15 seconds, at most 120), and prints for each job the Pods Running, Pods Pending (any Pod without a node), GPUs held and the node of every Pod. For gang runs, it also prints the PodGroup condition. It shows the scheduler's last `FailedScheduling` message for the first Pending Pod.

Manifests, in [`manifests/gang/`](../manifests/gang/). All Pods use `registry.k8s.io/pause:3.10`, request `cpu: 50m` and `memory: 32Mi`, and have a limit of `nvidia.com/gpu: 2`:

| File | Contents |
| --- | --- |
| `trainer.yaml` | 4 trainer Pods, no PodGroup |
| `trainer-gang.yaml` | Workload `trainer` and PodGroup `trainer-workers` (gang, `minCount: 4`), and the 4 trainer Pods referencing it |
| `deadlock.yaml` | job-a and job-b, 4 Pods each, listed interleaved (a-0, b-0, a-1, b-1, ...) so `kubectl apply` creates them in that order |
| `deadlock-gang.yaml` | The same, with a Workload and PodGroup (gang, `minCount: 4`) per job |

## Results

Cluster: kind v0.33.0, `kindest/node:v1.37.0`, 1 control plane and 3 workers with 4 fake GPUs each (12 in total), scheduler running `scheduler-config.yaml` with `GenericWorkload` enabled.

### Partial-start demo

The 6-pod `gpu-test` Deployment uses 6 GPUs first, leaving 6 free. The trainer job needs 8.

| | Without gang | With gang |
| --- | --- | --- |
| gpu-test | 6 Running, 6 GPUs | 6 Running, 6 GPUs |
| trainer Running | 3 | 0 |
| trainer Pending | 1 | 4 |
| GPUs held by trainer | **6** | **0** |
| PodGroup `trainer-workers` | n/a | `PodGroupInitiallyScheduled=False`, reason `Unschedulable` |

Without gang, three trainer Pods were bound: one on the worker gpu-test had left with 2 free GPUs and two on the worker it had left empty. trainer-3 stayed Pending. Which workers these are varies between runs, because the scheduler breaks ties between equally empty nodes at random:

```text
0/4 nodes are available: 1 node(s) had untolerated taint(s), 3 Insufficient nvidia.com/gpu.
```

With gang, no trainer Pod was bound:

```text
pod group is unschedulable, pod group is unschedulable, 0/1 placements are available,
first placement status: minCount (4) cannot be satisfied: 3 scheduled, 0 remaining,
pod group preemption: No preemption victims found for incoming preemptor
```

This message, and the one quoted in the deadlock demo below, are from the cluster with `TopologyAwareWorkloadScheduling` also enabled (see [topology-aware placement](topology-aware-placement.md)): that gate routes gang groups through the placement-based scheduling algorithm, which changed the wording (a group without a topology constraint has one candidate placement, the whole cluster) but not the outcome.

"3 scheduled" here refers to the placement attempt inside the group cycle: the scheduler found room for 3 Pods. That is fewer than `minCount`, so it bound none of them. All 4 trainer Pods had no node, and the trainer held 0 GPUs.

### Deadlock demo

The cluster starts empty (12 GPUs free). job-a and job-b need 8 each, and their Pods are created interleaved.

| | Without gang | With gang |
| --- | --- | --- |
| job-a | 3 Running, 1 Pending, 6 GPUs | **4 Running**, 0 Pending, 8 GPUs |
| job-b | 3 Running, 1 Pending, 6 GPUs | 0 Running, **4 Pending**, 0 GPUs |
| Jobs fully started | **none** | **job-a** |
| PodGroups | n/a | `job-a-workers` `True` (`Scheduled`), `job-b-workers` `False` (`Unschedulable`) |

Without gang, each job got one Pod on each worker. Every worker was full and the -3 Pods of both jobs stayed Pending: 12 GPUs in use and neither job able to run.

With gang, job-a's 4 Pods were bound together and filled two workers, and the bin-packing configuration left the third worker free. Which workers are used varies between runs, because the scheduler breaks ties between equally empty nodes at random. job-b bound nothing:

```text
pod group is unschedulable, pod group is unschedulable, 0/1 placements are available,
first placement status: minCount (4) cannot be satisfied: 2 scheduled, 1 remaining,
pod group preemption: No preemption victims found for incoming preemptor
```

As an extra check, the job-a Pods were then deleted. Within about 12 seconds, all 4 job-b Pods were bound, filling two workers, and `job-b-workers` changed to `PodGroupInitiallyScheduled=True`. A waiting gang starts as soon as there is room for the whole group.

### Differences from expectations

All four runs matched the expected outcome. Two details are worth noting:

- The docs describe the PodGroup reference to its template as `spec.podGroupTemplateRef.workload.{workloadName, podGroupTemplateName}`. On the v1.37.0 API server, `kubectl explain podgroup.spec` shows `spec.workloadRef.{workloadName, templateName}` instead, so the manifests use that.
- The docs do not describe a gang scheduling timeout, and none was observed: a gang that does not fit waits in the unschedulable queue, holding no resources, until the cluster changes.
