#!/usr/bin/env python3
"""Seeded job mix for the KubeSchedulerConfiguration benchmark.

The same seed always gives the same jobs in the same order, so every
configuration sees an identical workload. GPU demand is split by share:

  small   single Pod, 1 or 2 GPUs                      25% of demand
  medium  2, 3 or 4 Pods x 2 GPUs                      35% of demand
  large   8 Pods x 8 GPUs (a whole node per Pod)       40% of demand

Total demand defaults to 120% of 8,000 GPUs. Jobs are shuffled so the three
kinds arrive interleaved.

Usage: workload.py [--seed 42] [--capacity 8000] [--overcommit 1.2]   (prints a summary)
"""

import argparse
import collections
import random

SHARES = {"large": 0.40, "medium": 0.35, "small": 0.25}
GPUS_PER_NODE = 8
# CPU and memory per GPU requested by every Pod: a third of the node's
# per-GPU share (96 CPU and 768Gi per 8 GPUs), so GPUs are the binding limit.
CPU_PER_GPU = "4"
MEM_PER_GPU_GI = 32


def generate(seed=42, capacity=8000, overcommit=1.2):
    """Return a list of jobs: {name, kind, pods, gpus_per_pod}."""
    rng = random.Random(seed)
    demand = capacity * overcommit
    jobs = []

    large_gpus = 8 * GPUS_PER_NODE
    for _ in range(round(demand * SHARES["large"] / large_gpus)):
        jobs.append({"kind": "large", "pods": 8, "gpus_per_pod": GPUS_PER_NODE})

    target, total = demand * SHARES["medium"], 0
    while total < target:
        pods = rng.choice([2, 3, 4])
        jobs.append({"kind": "medium", "pods": pods, "gpus_per_pod": 2})
        total += pods * 2

    target, total = demand * SHARES["small"], 0
    while total < target:
        gpus = rng.choice([1, 2])
        jobs.append({"kind": "small", "pods": 1, "gpus_per_pod": gpus})
        total += gpus

    rng.shuffle(jobs)
    for i, job in enumerate(jobs):
        job["name"] = f"job-{i:04d}-{job['kind']}"
    return jobs


def summary(jobs, capacity=8000):
    by_kind = collections.OrderedDict((k, [0, 0, 0]) for k in ("small", "medium", "large"))
    for j in jobs:
        s = by_kind[j["kind"]]
        s[0] += 1
        s[1] += j["pods"]
        s[2] += j["pods"] * j["gpus_per_pod"]
    lines = [f"{'kind':<8} {'jobs':>6} {'pods':>6} {'gpus':>6}"]
    for k, (n, p, g) in by_kind.items():
        lines.append(f"{k:<8} {n:>6} {p:>6} {g:>6}")
    n, p, g = (sum(v[i] for v in by_kind.values()) for i in range(3))
    lines.append(f"{'total':<8} {n:>6} {p:>6} {g:>6}  ({g / capacity:.1%} of {capacity} GPUs)")
    return "\n".join(lines)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--capacity", type=int, default=8000)
    p.add_argument("--overcommit", type=float, default=1.2)
    a = p.parse_args()
    print(summary(generate(a.seed, a.capacity, a.overcommit), a.capacity))
