#!/usr/bin/env python3
"""Create simulated GPU nodes for the KubeSchedulerConfiguration benchmark.

Default: 1,000 nodes in 50 racks of 20, each with 8 nvidia.com/gpu, 96 CPU,
768Gi memory and 110 pods. Racks alternate between two GPU models. The
kwok-controller (started with --manage-all-nodes) keeps them Ready and marks
pods bound to them Running; no kubelets run.

Usage: nodes.py --kubeconfig PATH [--nodes 1000] [--racks 50]
"""

import argparse
import concurrent.futures
import sys
import time

from kube import Client

GPU_MODELS = ["nvidia-h100", "nvidia-a100"]


def node(i, racks, per_rack):
    rack = i // per_rack + 1
    name = f"gpu-node-{i + 1:04d}"
    resources = {"cpu": "96", "memory": "768Gi", "nvidia.com/gpu": "8", "pods": "110"}
    return {
        "apiVersion": "v1",
        "kind": "Node",
        "metadata": {
            "name": name,
            "labels": {
                "kubernetes.io/hostname": name,
                "kubernetes.io/os": "linux",
                "kubernetes.io/arch": "amd64",
                "type": "kwok",
                "topology.rack": f"rack-{rack:02d}",
                "gpu.model": GPU_MODELS[(rack - 1) % len(GPU_MODELS)],
            },
        },
        "status": {
            "capacity": resources,
            "allocatable": resources,
            "nodeInfo": {"architecture": "amd64", "operatingSystem": "linux", "kubeletVersion": "fake"},
        },
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--kubeconfig", required=True)
    p.add_argument("--nodes", type=int, default=1000)
    p.add_argument("--racks", type=int, default=50)
    args = p.parse_args()
    if args.nodes % args.racks:
        sys.exit("--nodes must be a multiple of --racks")
    per_rack = args.nodes // args.racks

    client = Client(args.kubeconfig)
    with concurrent.futures.ThreadPoolExecutor(16) as pool:
        list(pool.map(lambda i: client.create("/api/v1/nodes", node(i, args.racks, per_rack)), range(args.nodes)))

    # Wait until every node is Ready and untainted, so no node is skipped
    # at the start of a run.
    deadline = time.time() + 300
    while True:
        items, _ = client.list("/api/v1/nodes?labelSelector=type%3Dkwok")
        ready = sum(1 for n in items
                    if not n["spec"].get("taints")
                    and any(c["type"] == "Ready" and c["status"] == "True" for c in n["status"].get("conditions", [])))
        if ready == args.nodes:
            break
        if time.time() > deadline:
            sys.exit(f"only {ready} of {args.nodes} nodes Ready after 300s")
        time.sleep(2)
    print(f"{args.nodes} nodes Ready in {args.racks} racks of {per_rack}, "
          f"{args.nodes * 8} nvidia.com/gpu in total")


if __name__ == "__main__":
    main()
