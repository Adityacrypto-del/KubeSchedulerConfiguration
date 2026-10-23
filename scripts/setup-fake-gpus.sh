#!/usr/bin/env bash
# Gives each worker in the sched-dev kind cluster 4 fake nvidia.com/gpu and
# labels them with GPU model and rack topology. Safe to re-run: the JSON patch
# "add" op replaces an existing value and labels are applied with --overwrite.
set -euo pipefail

CLUSTER="${CLUSTER:-sched-dev}"
GPUS_PER_NODE="${GPUS_PER_NODE:-4}"

for node in "${CLUSTER}-worker" "${CLUSTER}-worker2" "${CLUSTER}-worker3"; do
  case "$node" in
    *-worker3) rack=rack-2 ;;
    *) rack=rack-1 ;;
  esac
  kubectl patch node "$node" --subresource=status --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/status/capacity/nvidia.com~1gpu\",\"value\":\"${GPUS_PER_NODE}\"}]"
  kubectl label node "$node" gpu.model=a100 "topology.rack=${rack}" --overwrite
done

# The kubelet derives allocatable from capacity; wait until it is reported.
for node in "${CLUSTER}-worker" "${CLUSTER}-worker2" "${CLUSTER}-worker3"; do
  for _ in $(seq 1 30); do
    alloc=$(kubectl get node "$node" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
    [[ "$alloc" == "$GPUS_PER_NODE" ]] && break
    sleep 1
  done
done

kubectl get nodes -l gpu.model=a100 \
  -o custom-columns='NODE:.metadata.name,GPU_CAPACITY:.status.capacity.nvidia\.com/gpu,GPU_ALLOCATABLE:.status.allocatable.nvidia\.com/gpu,RACK:.metadata.labels.topology\.rack'
