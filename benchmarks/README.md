# Scale benchmark

Compares four KubeSchedulerConfiguration setups on a KWOK cluster of 1,000 simulated GPU nodes (8,000 `nvidia.com/gpu`). Design, metric definitions and results are in [docs/benchmark.md](../docs/benchmark.md).

The benchmark uses its own cluster, `sched-bench`, created with kwokctl. It does not touch the `sched-dev` kind cluster, and it writes its kubeconfig to `~/.kwok/sched-bench.kubeconfig` (override with `BENCH_KUBECONFIG`), so `~/.kube/config` and its current context are unchanged.

## Requirements

- kwokctl v0.8.0 and kubectl v1.37 (`brew install kwok kubectl`)
- Docker (OrbStack on macOS). kwokctl runs the control plane as containers: etcd, kube-apiserver, kube-controller-manager, kube-scheduler and kwok-controller, all v1.37.0.
- Python 3 with matplotlib (only `summarize.py` needs matplotlib; everything else is standard library)
- About 1.5 GiB of free Docker memory. The control plane used about 1 GiB during a run, most of it kube-apiserver.

## Run everything

From the repository root:

```bash
benchmarks/bench.sh
```

This runs every config 3 times, each on a fresh cluster, then deletes the cluster and summarises. A full run takes about 15 minutes. Options, as environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `RUNS` | 3 | Runs per config |
| `RATE` | 1000 | Submission rate in Pods per second |
| `SEED` | 42 | Workload seed |

To run some configs only: `benchmarks/bench.sh binpack binpack-gang`.

A run is discarded and repeated if cluster setup or `run.py` fails (for example a submit error, or nodes not Ready), or `run.py` detects a wall-clock jump of more than 5 seconds (for example the Mac slept). Discarded runs are moved to `results/<config>/discarded-<time>/` and listed in `results/discarded.txt`. Runs that already have a valid `metrics.json` are skipped, so an interrupted benchmark can simply be started again; delete `benchmarks/results/` to start from scratch.

`bench.sh` runs under `caffeinate -i` on macOS, but that cannot stop sleep when a laptop's lid is closed on battery. Keep the lid open or the charger connected for the whole run.

## Run the steps by hand

```bash
benchmarks/cluster.sh create binpack-gang          # any name from benchmarks/configs/*.env
python3 benchmarks/nodes.py --kubeconfig ~/.kwok/sched-bench.kubeconfig
python3 benchmarks/run.py --kubeconfig ~/.kwok/sched-bench.kubeconfig \
  --mode gang --rate 1000 --out /tmp/bench-run      # mode must match WORKLOAD_MODE in the .env file
benchmarks/cluster.sh delete
python3 benchmarks/workload.py                      # print the job mix
python3 benchmarks/summarize.py                     # rebuild summary and charts from results/
```

## Files

| File | Purpose |
| --- | --- |
| `kwokctl.yaml` | kwokctl settings shared by all configs: docker runtime, Kubernetes v1.37.0, QPS limits lifted |
| `configs/<name>.env` | One per config: scheduler config file, feature gates, runtime config, workload mode |
| `configs/stock-scheduler-config.yaml` | Default scheduler profile for `stock`. The other configs use the repository's `scheduler-config.yaml` directly. |
| `cluster.sh` | Creates `sched-bench` for a config, or deletes it. Adds the same `clientConnection` qps and burst to every scheduler config. |
| `nodes.py` | Creates 1,000 nodes in 50 racks of 20 and waits until all are Ready |
| `workload.py` | Seeded job mix, identical for every config |
| `run.py` | Submits the jobs at a fixed rate, watches binds, writes `metrics.json`, `metrics.csv` and `pods.csv` |
| `kube.py` | Small Kubernetes REST client used by the Python scripts |
| `bench.sh` | Runs everything and discards interrupted runs |
| `summarize.py` | Reads each run's `metrics.csv`; median and min–max per config into `results/summary.{csv,json}`, charts into `docs/` |
| `results/` | Raw results: `results/<config>/run-<n>/` |
