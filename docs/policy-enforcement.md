# Policy enforcement

## Why admission policies on a GPU platform

Bin-packing, gang scheduling and topology-aware placement only help if workloads are written to use them. The scheduler cannot fix a Pod that is wrong when it arrives:

- **Unattributed GPU use.** GPUs are the most expensive resource in the cluster. Without an owner label on every GPU Pod, nobody can tell which team is using them or charge it back.
- **Pods that can never run.** A container that asks for more GPUs than any node has passes API validation, then stays Pending forever while users wonder why.
- **Distributed jobs without a gang.** A multi-Pod training job that forgets its PodGroup is scheduled Pod by Pod and brings back the partial starts and deadlocks described in [gang scheduling](gang-scheduling.md).
- **Jobs split across racks.** A PodGroup without a topology constraint can be placed across racks, the problem described in [topology-aware placement](topology-aware-placement.md).

Admission policies catch these when the object is submitted, with a message that says what to fix, instead of leaving users to discover them from a Pending Pod or a slow job.

## How Kyverno fits in

Kyverno runs in the cluster as an admission controller. The API server sends matching create and update requests to Kyverno's webhooks before storing the object:

```text
kubectl apply ──▶ kube-apiserver ──▶ mutating webhook (Kyverno: default-rack-topology)
                                 ──▶ schema validation
                                 ──▶ validating webhook (Kyverno: the three validate policies)
                                 ──▶ stored in etcd ──▶ kube-scheduler
```

A mutate policy changes the object before it is stored. A validate policy in `Enforce` mode rejects the request with the policy's message. Nothing changes in the scheduler: Kyverno only decides what reaches it.

### Version

Kyverno is installed from the Helm chart `kyverno/kyverno` version **3.9.2** (Kyverno **v1.19.2**), pinned in [`scripts/install-kyverno.sh`](../scripts/install-kyverno.sh). This is the latest chart in the Kyverno Helm repository. The [Kyverno releases page](https://kyverno.io/docs/releases/) lists v1.19 as tested on Kubernetes v1.33 to v1.35 and says other versions "may work, but are not tested". No Kyverno release lists v1.37, so on this v1.37.0 cluster it is untested upstream. Every result below was checked on the running cluster.

Policies use `apiVersion: kyverno.io/v1`, `kind: ClusterPolicy`, the version this chart serves and stores. Two notes from the cluster:

- `kubectl explain clusterpolicy.spec.validationFailureAction` marks the policy-wide field as deprecated in favour of `failureAction` on each validate rule, so the policies set `validate.failureAction: Enforce`. This is the same `Enforce` behaviour.
- Kyverno v1.19 marks the whole `kyverno.io/v1` ClusterPolicy type as deprecated and prints a warning on every apply. The replacements are the CEL-based `policies.kyverno.io/v1` types (`ValidatingPolicy`, `MutatingPolicy`). They are installed by the same chart, and the [migration guide](https://kyverno.io/docs/guides/migration-to-cel/) describes the move.

## Namespace scoping

Every policy matches only namespaces labelled `gpu-policy=enforced`. [`manifests/policy/namespace.yaml`](../manifests/policy/namespace.yaml) creates `ml-team-a` with that label.

- The existing demos run in `default`, and their manifests (for example the 6-pod `gpu-test` Deployment) have no `team` label. Scoping by label keeps them working unchanged.
- Namespaces opt in one at a time, so a platform team can turn policies on per team, without a cluster-wide change that might break running workloads.

In addition, [`deploy/kyverno/values.yaml`](../deploy/kyverno/values.yaml) sets the webhook `namespaceSelector` so the API server never sends requests from `kube-system` or `kyverno` to Kyverno's webhooks. That keeps control-plane and Kyverno's own Pods out of the admission path even if a later policy is written more broadly.

## Policies

All files are in [`policies/`](../policies/).

| Policy | Type | Enforces | Why |
| --- | --- | --- | --- |
| [`require-team-label`](../policies/require-team-label.yaml) | validate, Enforce | A Pod with any container (or init container) that has an `nvidia.com/gpu` limit must have a non-empty `team` label. | GPU use can be attributed to a team. Pods without GPUs are not affected. |
| [`max-gpus-per-pod`](../policies/max-gpus-per-pod.yaml) | validate, Enforce | No container (or init container) may set an `nvidia.com/gpu` limit above 4. | A container larger than one node can never be scheduled. The limit is the `maxGpusPerNode` context variable, with a comment to change it to match node size. |
| [`distributed-jobs-require-gang`](../policies/distributed-jobs-require-gang.yaml) | validate, Enforce | A Pod labelled `job-type: distributed` must set `spec.schedulingGroup.podGroupName`. | Distributed jobs are gang scheduled, so they start all at once or not at all. |
| [`default-rack-topology`](../policies/default-rack-topology.yaml) | mutate | A PodGroup created without `spec.schedulingConstraints` gets `schedulingConstraints.topology: [{key: topology.rack}]`. A PodGroup that sets its own constraints is left unchanged. | Gang jobs stay within one rack by default. |

Details:

- **GPU limits, not requests.** Kubernetes requires extended resources such as `nvidia.com/gpu` to be set in `limits` (a request, if given, must equal the limit), so checking limits finds every GPU container.
- **Field names.** They were confirmed with `kubectl explain` on the cluster: `pod.spec.schedulingGroup.podGroupName`, and `podgroup.spec.schedulingConstraints.topology[].key` (scheduling.k8s.io/v1beta1). `kubectl explain` notes that `schedulingConstraints` is immutable and exists only with the `TopologyAwareWorkloadScheduling` gate, which is enabled in `kind-config.yaml`.
- **CREATE only.** Because the field is immutable, `default-rack-topology` matches only CREATE. It uses the `+(schedulingConstraints)` add anchor, which adds the field only when it is absent.
- **Mutating a beta resource.** Kyverno mutated the beta `scheduling.k8s.io/v1beta1` PodGroup on this cluster without problems (results below), so no validate fallback was needed.
- **No background scans.** All policies set `background: false`, so they act only at admission and do not report on objects that already exist.

## Install and reproduce

Starting from the cluster described in the [README](../README.md), with fake GPUs from `scripts/setup-fake-gpus.sh`:

```bash
./scripts/install-kyverno.sh                    # install or upgrade, waits until ready
kubectl apply -f manifests/policy/namespace.yaml
kubectl apply -f policies/
kubectl get clusterpolicies                     # all four READY True

./scripts/policy-demo.sh
```

[`scripts/policy-demo.sh`](../scripts/policy-demo.sh) applies each example from [`manifests/policy/examples/`](../manifests/policy/examples/) in `ml-team-a`:

- Validate examples use `kubectl apply --dry-run=server`, which runs admission, Kyverno included, without storing anything.
- It also applies the failing team-label example in `default` to show the namespace scoping.
- For the mutate policy, it prints the spec returned by a server dry run, then creates each PodGroup for real, prints the stored spec and deletes it.
- At the end, it prints a results table.

## Results

Cluster: kind v0.33.0, `kindest/node:v1.37.0`, 1 control plane and 3 workers with 4 fake GPUs each, `GenericWorkload` and `TopologyAwareWorkloadScheduling` enabled, Kyverno v1.19.2 (chart 3.9.2). Output of `./scripts/policy-demo.sh`:

| Policy | Example | Expected | Actual |
| --- | --- | --- | --- |
| require-team-label | require-team-label-pass | allowed | allowed |
| require-team-label | require-team-label-fail | denied | denied: Pods that request nvidia.com/gpu must have a non-empty `team` label, for example `team: ml-team-a`. |
| max-gpus-per-pod | max-gpus-per-pod-pass | allowed | allowed |
| max-gpus-per-pod | max-gpus-per-pod-fail | denied | denied: A container requests more nvidia.com/gpu than one node holds (4). Split the job into more Pods, each requesting at most 4 GPUs. |
| distributed-jobs-require-gang | distributed-jobs-require-gang-pass | allowed | allowed |
| distributed-jobs-require-gang | distributed-jobs-require-gang-fail | denied | denied: Pods labelled `job-type: distributed` must reference a PodGroup in spec.schedulingGroup.podGroupName so the job is gang scheduled. |
| require-team-label | require-team-label-fail (ns default) | allowed | allowed |
| default-rack-topology | default-rack-topology-unchanged | unchanged | unchanged: schedulingConstraints `{"topology":[{"key":"kubernetes.io/hostname"}]}` |
| default-rack-topology | default-rack-topology-mutated | mutated | mutated: schedulingConstraints `{"topology":[{"key":"topology.rack"}]}` |

Stored spec of the mutated PodGroup, which was created without `schedulingConstraints`:

```json
{"disruptionMode":{"single":{}},"priority":0,"schedulingConstraints":{"topology":[{"key":"topology.rack"}]},"schedulingPolicy":{"gang":{"minCount":2}}}
```

`disruptionMode` and `priority` are defaults filled in by the API server, not by the policy.

### No regressions

With Kyverno and the four policies installed, on the same cluster:

| Check | Result |
| --- | --- |
| `./scripts/gang-demo.sh partial gang` | gpu-test 6 Running; trainer 0 Running, 4 Pending, 0 GPUs held; `trainer-workers` `PodGroupInitiallyScheduled=False` (`Unschedulable`) |
| `./scripts/gang-demo.sh deadlock gang` | job-a 4 Running (8 GPUs); job-b 0 Running, 4 Pending; `job-a-workers` `True`, `job-b-workers` `False` |
| `./scripts/topology-demo.sh with-topology` | all 4 trainer Pods in rack-1, `PodGroupInitiallyScheduled=True` |
| `manifests/gpu-test.yaml` alone | 4 / 2 / 0 Pods per worker: packed, one worker left empty |

These match the results before Kyverno was added. The demos run in `default`, which has no `gpu-policy` label, so no policy matched them. Which worker ends up full, half used or empty varies between runs, because the scheduler breaks ties between equally empty nodes at random.

### Differences from expectations

All examples behaved as expected. Points worth noting:

- **Kubernetes version support.** No Kyverno release lists Kubernetes v1.37 as tested; the latest, v1.19, lists v1.33 to v1.35. It installed and worked correctly here, but that is not an upstream guarantee.
- **Deprecated policy type.** `kyverno.io/v1` ClusterPolicy works but is deprecated in v1.19, and every `kubectl apply` or `get` of these policies prints a deprecation warning. `scripts/policy-demo.sh` hides that warning from its output. Moving to `ValidatingPolicy` and `MutatingPolicy` is the long-term path.
- **`validationFailureAction`.** The policy-wide `spec.validationFailureAction: Enforce` is deprecated, so the rule-level `validate.failureAction: Enforce` is used instead, with the same effect.
- **Mutation worked directly.** The beta PodGroup resource could be mutated directly, so `default-rack-topology` stayed a mutate policy.
