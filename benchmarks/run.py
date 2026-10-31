#!/usr/bin/env python3
"""Submit the benchmark job mix to a sched-bench cluster and measure placement.

Jobs from workload.py are submitted in order at a fixed rate in Pods per
second: job j starts at (Pods in jobs before j) / rate seconds, and its Pods
are created back to back. A watch on Pods records, on this machine's clock,
when each Pod is first seen with spec.nodeName set (bound). After the last
job, the run waits until no Pod has been bound for --quiet seconds, then reads
the final Pods and nodes and writes:

  metrics.json  all metrics (see docs/benchmark.md for definitions)
  metrics.csv   the same, one row
  pods.csv      one row per Pod: job, kind, GPUs, node, rack, submit and bind times

Usage: run.py --kubeconfig PATH --mode plain|gang|gang-topology --out DIR
              [--rate 100] [--seed 42] [--quiet 45] [--timeout 1200]
"""

import argparse
import collections
import concurrent.futures
import csv
import json
import os
import statistics
import sys
import threading
import time

import workload
from kube import Client

NS = "bench"
GPU = "nvidia.com/gpu"


def pod_manifest(job, i, mode):
    gpus = job["gpus_per_pod"]
    spec = {
        "terminationGracePeriodSeconds": 0,
        "containers": [{
            "name": "main",
            "image": "registry.k8s.io/pause:3.10",
            "resources": {
                "requests": {"cpu": str(int(workload.CPU_PER_GPU) * gpus), "memory": f"{workload.MEM_PER_GPU_GI * gpus}Gi"},
                "limits": {GPU: str(gpus)},
            },
        }],
    }
    if mode != "plain" and job["pods"] > 1:
        spec["schedulingGroup"] = {"podGroupName": job["name"]}
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {"name": f"{job['name']}-{i}", "labels": {"bench/job": job["name"], "bench/kind": job["kind"]}},
        "spec": spec,
    }


def gang_manifests(job, mode):
    policy = {"gang": {"minCount": job["pods"]}}
    template = {"name": "workers", "schedulingPolicy": policy}
    group = {"workloadRef": {"workloadName": job["name"], "templateName": "workers"}, "schedulingPolicy": policy}
    if mode == "gang-topology":
        constraints = {"topology": [{"key": "topology.rack"}]}
        template["schedulingConstraints"] = constraints
        group["schedulingConstraints"] = constraints
    meta = {"name": job["name"], "labels": {"bench/job": job["name"], "bench/kind": job["kind"]}}
    wl = {"apiVersion": "scheduling.k8s.io/v1beta1", "kind": "Workload", "metadata": meta,
          "spec": {"podGroupTemplates": [template]}}
    pg = {"apiVersion": "scheduling.k8s.io/v1beta1", "kind": "PodGroup", "metadata": meta, "spec": group}
    return wl, pg


class Recorder:
    """Watches Pods in the namespace and records first-bound times."""

    def __init__(self, client):
        self.client = client
        self.bound = {}           # pod name -> (wall time first seen bound, node)
        self.lock = threading.Lock()
        self.last_bind = None
        self.restarts = 0

    def _see(self, pod, now):
        node = pod["spec"].get("nodeName")
        name = pod["metadata"]["name"]
        if node and name not in self.bound:
            with self.lock:
                self.bound[name] = (now, node)
                self.last_bind = now

    def run(self):
        path = f"/api/v1/namespaces/{NS}/pods"
        while True:
            items, rv = self.client.list(path)
            now = time.time()
            for p in items:
                self._see(p, now)
            try:
                for typ, obj in self.client.watch(path, rv):
                    if typ in ("ADDED", "MODIFIED"):
                        self._see(obj, time.time())
                    elif typ == "ERROR":
                        break
            except Exception as e:  # reconnect and relist
                print(f"   watch restarted: {e}", file=sys.stderr)
            self.restarts += 1


class SleepDetector:
    """Flags runs where this machine stalled or slept (wall clock jumps)."""

    def __init__(self):
        self.max_gap = 0.0
        self.stop = False

    def run(self):
        last = time.time()
        while not self.stop:
            time.sleep(0.5)
            now = time.time()
            self.max_gap = max(self.max_gap, now - last)
            last = now


def pct(values, q):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kubeconfig", required=True)
    ap.add_argument("--mode", choices=["plain", "gang", "gang-topology"], required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rate", type=float, default=100.0, help="Pods per second")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--quiet", type=float, default=45.0)
    ap.add_argument("--timeout", type=float, default=1200.0)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    client = Client(args.kubeconfig)
    jobs = workload.generate(args.seed)
    print(workload.summary(jobs))

    client.create("/api/v1/namespaces", {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": NS}})
    for _ in range(120):  # Pods cannot be created until the default ServiceAccount exists
        if client.request("GET", f"/api/v1/namespaces/{NS}/serviceaccounts/default")[0] == 200:
            break
        time.sleep(0.5)

    rec = Recorder(client)
    threading.Thread(target=rec.run, daemon=True).start()
    sleepdet = SleepDetector()
    threading.Thread(target=sleepdet.run, daemon=True).start()
    time.sleep(1)

    submit = {}  # pod name -> wall time the create request was sent
    errors = []

    def submit_job(job):
        try:
            if args.mode != "plain" and job["pods"] > 1:
                wl, pg = gang_manifests(job, args.mode)
                client.create(f"/apis/scheduling.k8s.io/v1beta1/namespaces/{NS}/workloads", wl)
                client.create(f"/apis/scheduling.k8s.io/v1beta1/namespaces/{NS}/podgroups", pg)
            for i in range(job["pods"]):
                pod = pod_manifest(job, i, args.mode)
                submit[pod["metadata"]["name"]] = time.time()
                client.create(f"/api/v1/namespaces/{NS}/pods", pod)
        except Exception as e:
            errors.append(f"{job['name']}: {e}")

    print(f"== Submitting {len(jobs)} jobs at {args.rate:g} Pods/s, mode {args.mode}")
    t0 = time.time()
    behind = 0.0
    with concurrent.futures.ThreadPoolExecutor(32) as pool:
        offset = 0
        for job in jobs:
            start = t0 + offset / args.rate
            delay = start - time.time()
            if delay > 0:
                time.sleep(delay)
            else:
                behind = max(behind, -delay)
            pool.submit(submit_job, job)
            offset += job["pods"]
    t_submitted = time.time()
    print(f"   submitted in {t_submitted - t0:.1f}s (dispatcher at most {behind:.2f}s behind schedule)")
    if errors:
        print(f"   {len(errors)} submit errors, first: {errors[0]}")

    total_pods = sum(j["pods"] for j in jobs)
    while True:
        time.sleep(1)
        now = time.time()
        quiet_since = rec.last_bind or t_submitted
        if len(rec.bound) == total_pods:
            break
        if now - max(quiet_since, t_submitted) >= args.quiet:
            break
        if now - t0 > args.timeout:
            print("   timeout waiting for binds to stop")
            break
    sleepdet.stop = True

    # Final state from the API server.
    pods, _ = client.list(f"/api/v1/namespaces/{NS}/pods")
    nodes, _ = client.list("/api/v1/nodes?labelSelector=type%3Dkwok")
    rack_of = {n["metadata"]["name"]: n["metadata"]["labels"]["topology.rack"] for n in nodes}
    gpu_alloc = {n["metadata"]["name"]: int(n["status"]["allocatable"].get(GPU, 0)) for n in nodes}
    capacity = sum(gpu_alloc.values())
    job_of = {f"{j['name']}-{i}": j for j in jobs for i in range(j["pods"])}

    used = collections.Counter()
    final_node = {}
    for p in pods:
        node = p["spec"].get("nodeName")
        if node:
            name = p["metadata"]["name"]
            final_node[name] = node
            used[node] += job_of[name]["gpus_per_pod"]

    # Latency and throughput from the recorded times.
    latencies = [rec.bound[n][0] - submit[n] for n in final_node if n in rec.bound and n in submit]
    bind_times = [rec.bound[n][0] for n in final_node if n in rec.bound]
    bound_pods = len(final_node)
    window = (max(bind_times) - t0) if bind_times else None

    gpus_bound = sum(used.values())
    free = {n: gpu_alloc[n] - used[n] for n in gpu_alloc}
    stranded = sum(f for f in free.values() if 0 < f < 8)

    multi = {"fully": 0, "partially": 0, "not": 0}
    held_partial = 0
    kind_counts = {k: {"jobs": 0, "fully": 0, "partially": 0, "not": 0} for k in ("small", "medium", "large")}
    one_rack = {"medium": [0, 0], "large": [0, 0]}  # [fully placed, of which in one rack]
    for j in jobs:
        names = [f"{j['name']}-{i}" for i in range(j["pods"])]
        placed = [n for n in names if n in final_node]
        state = "fully" if len(placed) == len(names) else ("partially" if placed else "not")
        kind_counts[j["kind"]]["jobs"] += 1
        kind_counts[j["kind"]][state] += 1
        if j["pods"] > 1:
            multi[state] += 1
            if state == "partially":
                held_partial += len(placed) * j["gpus_per_pod"]
            if state == "fully":
                one_rack[j["kind"]][0] += 1
                if len({rack_of[final_node[n]] for n in placed}) == 1:
                    one_rack[j["kind"]][1] += 1
    multi_fully = one_rack["medium"][0] + one_rack["large"][0]
    multi_one_rack = one_rack["medium"][1] + one_rack["large"][1]

    def r(x, d=3):
        return None if x is None else round(x, d)

    metrics = {
        "mode": args.mode,
        "seed": args.seed,
        "rate_pods_per_s": args.rate,
        "pods_submitted": len(submit),
        "submit_errors": len(errors),
        "submit_seconds": r(t_submitted - t0, 1),
        "pods_bound": bound_pods,
        "throughput_pods_per_s": r(bound_pods / window if window else None, 1),
        "bind_window_s": r(window, 1),
        "latency_p50_s": r(pct(latencies, 0.50)),
        "latency_p95_s": r(pct(latencies, 0.95)),
        "latency_p99_s": r(pct(latencies, 0.99)),
        "gpu_capacity": capacity,
        "gpus_bound": gpus_bound,
        "gpu_utilisation": r(gpus_bound / capacity, 4),
        "stranded_gpus": stranded,
        "nodes_fully_free": sum(1 for f in free.values() if f == 8),
        "multi_pod_jobs": sum(multi.values()),
        "multi_pod_fully_placed": multi["fully"],
        "multi_pod_partially_placed": multi["partially"],
        "multi_pod_not_placed": multi["not"],
        "gpus_held_by_partial_jobs": held_partial,
        "large_jobs": kind_counts["large"]["jobs"],
        "large_jobs_fully_placed": kind_counts["large"]["fully"],
        "multi_pod_one_rack_fraction": r(multi_one_rack / multi_fully if multi_fully else None, 4),
        "medium_one_rack_fraction": r(one_rack["medium"][1] / one_rack["medium"][0] if one_rack["medium"][0] else None, 4),
        "large_one_rack_fraction": r(one_rack["large"][1] / one_rack["large"][0] if one_rack["large"][0] else None, 4),
        "jobs_by_kind": kind_counts,
        "max_clock_gap_s": r(sleepdet.max_gap, 2),
        "interrupted": sleepdet.max_gap > 5,
        "watch_restarts": rec.restarts,
    }

    with open(os.path.join(args.out, "metrics.json"), "w") as f:
        json.dump(metrics, f, indent=2)
    flat = {k: v for k, v in metrics.items() if not isinstance(v, dict)}
    with open(os.path.join(args.out, "metrics.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(flat))
        w.writeheader()
        w.writerow(flat)
    with open(os.path.join(args.out, "pods.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["pod", "job", "kind", "gpus", "node", "rack", "submit_s", "bound_s", "latency_s"])
        for name, job in job_of.items():
            node = final_node.get(name, "")
            sub = submit.get(name)
            b = rec.bound.get(name, (None,))[0] if node else None
            w.writerow([name, job["name"], job["kind"], job["gpus_per_pod"], node, rack_of.get(node, ""),
                        r(sub - t0) if sub else "", r(b - t0) if b else "", r(b - sub) if b and sub else ""])

    for k, v in flat.items():
        print(f"   {k}: {v}")
    if metrics["interrupted"]:
        print("   WARNING: clock gap over 5s, this run was interrupted and should be discarded")
    if latencies and min(latencies) < 0:
        print(f"   WARNING: negative latency {min(latencies):.3f}s")
    if errors:
        sys.exit(f"{len(errors)} jobs failed to submit; this run is not valid")


if __name__ == "__main__":
    main()
