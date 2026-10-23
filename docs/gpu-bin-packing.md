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

Baseline with the stock scheduler (this replaces the cluster above):

```bash
./scripts/compare-default.sh
```

The test workload, [`manifests/gpu-test.yaml`](../manifests/gpu-test.yaml), is a Deployment of 6 `registry.k8s.io/pause:3.10` replicas, each requesting `cpu: 50m`, `memory: 32Mi` and a limit of `nvidia.com/gpu: 1`.

## Results

Cluster: kind v0.33.0, `kindest/node:v1.37.0`, 1 control plane and 3 workers with 4 fake GPUs each. Pods per worker for the 6-replica Deployment:

| Worker | Default scheduler | This configuration |
| --- | --- | --- |
| sched-dev-worker | 2 | 2 |
| sched-dev-worker2 | 2 | 4 |
| sched-dev-worker3 | 2 | 0 |

The custom configuration gave the same 2/4/0 placement on two separate cluster creations.

With the default scheduler, 6 GPUs are free but split 2/2/2, so no node can run a 4-GPU job. With this configuration, one worker is full, one is half used and `sched-dev-worker3` has all 4 GPUs free.

Why it lands this way: the first Pod sees three equally empty nodes and goes to one of them. From then on, `MostAllocated` scores the node with the most GPUs in use highest, so Pods follow it until it is full and the filter phase excludes it. The next Pod starts a second node and the remaining Pod follows it there. With the default spread constraints cleared, nothing pulls replicas apart.
