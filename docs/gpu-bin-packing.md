# GPU bin-packing

## Goal

Make the built-in kube-scheduler pack Pods that request `nvidia.com/gpu` onto as few nodes as possible, so that whole nodes stay free for large multi-GPU jobs. This is done with configuration only: no Go code and no custom scheduler.

## What changed and why

The stock scheduler spreads Pods out. Two things cause that:

- `NodeResourcesFit` scores nodes with the `LeastAllocated` strategy, which prefers the emptiest node.
- `PodTopologySpread` applies system default constraints that push replicas of the same workload onto different nodes, even when the Pod spec does not ask for it.

[`scheduler-config.yaml`](../scheduler-config.yaml) changes the scoring:

| Setting | Value | Why |
| --- | --- | --- |
| `clientConnection.kubeconfig` | `/etc/kubernetes/scheduler.conf` | With `--config` set, the scheduler ignores its `--kubeconfig` flag, so the config file must say how to reach the API server. |
| `NodeResourcesFit` score weight | `5` | Makes packing dominate the other score plugins, which keep their default weights. |
| `NodeResourcesFit` `scoringStrategy.type` | `MostAllocated` | Prefers nodes that are already busy. |
| `scoringStrategy.resources` | `nvidia.com/gpu` 10, `cpu` 1, `memory` 1 | GPU usage decides placement; CPU and memory barely count. |
| `PodTopologySpread` | `defaultingType: List`, `defaultConstraints: []` | Removes the system default spreading, which would otherwise fight bin-packing. |

[`kind-config.yaml`](../kind-config.yaml) mounts the file into the control-plane node and passes it to the scheduler through a kubeadm `ClusterConfiguration` patch (`extraArgs` `config=/etc/kubernetes/scheduler-config.yaml` plus a matching `extraVolume`). Kubernetes 1.37 uses kubeadm v1beta4, where `extraArgs` is a list of `{name, value}`; that form works with kind v0.33.0.

GPUs are simulated: [`scripts/setup-fake-gpus.sh`](../scripts/setup-fake-gpus.sh) patches each worker's status to advertise 4 `nvidia.com/gpu` and adds `gpu.model` and `topology.rack` labels.

## Reproduce

Requirements: Docker (OrbStack on macOS), kind v0.33.0, kubectl. If your clone is not at `/Users/adityaarasamangalam/KubeSchedulerConfiguration`, update the `hostPath` in `kind-config.yaml` first.

With the custom configuration:

```bash
kind delete cluster --name sched-dev
kind create cluster --name sched-dev --config kind-config.yaml
kubectl -n kube-system get pod -l component=kube-scheduler \
  -o jsonpath='{.items[0].spec.containers[0].command}'   # includes --config=/etc/kubernetes/scheduler-config.yaml
./scripts/setup-fake-gpus.sh
kubectl apply -f manifests/gpu-test.yaml
kubectl rollout status deployment/gpu-test
kubectl get pods -l app=gpu-test -o wide
```

Side-by-side comparison. Each run recreates the cluster, places the 6-pod Deployment, then submits the 4-GPU pod and reports whether it is Running or Pending (with the scheduler's reason). Run `custom` last to leave the custom-config cluster running:

```bash
./scripts/compare-default.sh default   # stock scheduler
./scripts/compare-default.sh custom    # scheduler-config.yaml
```

The test workload, [`manifests/gpu-test.yaml`](../manifests/gpu-test.yaml), is a Deployment of 6 `registry.k8s.io/pause:3.10` replicas, each requesting `cpu: 50m`, `memory: 32Mi` and a limit of `nvidia.com/gpu: 1`. The large job, [`manifests/gpu-large-job.yaml`](../manifests/gpu-large-job.yaml), is a single `registry.k8s.io/pause:3.10` pod with a limit of `nvidia.com/gpu: 4`, so it needs one worker with all of its GPUs free.

## Results

Cluster: kind v0.33.0, `kindest/node:v1.37.0`, 1 control plane and 3 workers with 4 fake GPUs each. Output of `./scripts/compare-default.sh default` and `./scripts/compare-default.sh custom`:

| | Default scheduler | This configuration |
| --- | --- | --- |
| gpu-test pods on sched-dev-worker | 2 | 0 |
| gpu-test pods on sched-dev-worker2 | 2 | 4 |
| gpu-test pods on sched-dev-worker3 | 2 | 2 |
| 4-GPU `gpu-large-job` | **Pending** | **Running** on sched-dev-worker |

The scheduler's reason for the Pending pod with the default configuration:

```text
0/4 nodes are available: 1 node(s) had untolerated taint(s), 3 Insufficient nvidia.com/gpu.
preemption: 0/4 nodes are available: 1 Preemption is not helpful for scheduling,
3 No preemption victims found for incoming pod.
```

The tainted node is the control plane; each of the three workers has only 2 GPUs free.

With the default scheduler, 6 GPUs are free but split 2/2/2, so the 4-GPU job cannot run anywhere. With this configuration, the same 6 pods leave one worker completely free, and the 4-GPU job is scheduled onto it.

Which worker ends up empty varies between cluster creations, because the first pod breaks a tie between three equally empty nodes. Two earlier runs of the custom configuration placed the Deployment 2/4/0 (worker, worker2, worker3); the run above placed it 0/4/2. The shape is the same every time: one full worker, one with 2 pods and one empty.

Why it lands this way: the first Pod sees three equally empty nodes and goes to one of them. From then on, `MostAllocated` scores the node with the most GPUs in use highest, so Pods follow it until it is full and the filter phase excludes it. The next Pod starts a second node and the remaining Pod follows it there. With the default spread constraints cleared, nothing pulls replicas apart.
