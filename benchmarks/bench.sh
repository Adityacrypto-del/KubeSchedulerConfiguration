#!/usr/bin/env bash
# Run the KubeSchedulerConfiguration scale benchmark: for each config, RUNS runs,
# each on a freshly created sched-bench KWOK cluster with 1,000 simulated GPU
# nodes. Results go to benchmarks/results/<config>/run-<n>/.
#
# Usage:
#   benchmarks/bench.sh [config ...]     # default: stock binpack binpack-gang binpack-gang-topology
#
# Environment: RUNS (default 3), RATE in Pods per second (default 1000),
# SEED (default 42).
#
# A run is discarded and repeated (up to 2 extra attempts per run) if cluster
# setup or run.py fails, or run.py reports that the clock jumped (for example
# the Mac slept). Runs that already have a valid metrics.json are skipped, so
# an interrupted benchmark can be restarted; delete results/ to start over.
# Discarded runs are kept as results/<config>/discarded-<time>/ and listed in
# results/discarded.txt. The sched-bench cluster is deleted at the end.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
BENCH_DIR="$REPO_ROOT/benchmarks"
RESULTS="$BENCH_DIR/results"
RUNS="${RUNS:-3}"
RATE="${RATE:-1000}"
SEED="${SEED:-42}"
export BENCH_KUBECONFIG="${BENCH_KUBECONFIG:-$HOME/.kwok/sched-bench.kubeconfig}"

configs=("$@")
[[ ${#configs[@]} -gt 0 ]] || configs=(stock binpack binpack-gang binpack-gang-topology)

trap '"$BENCH_DIR/cluster.sh" delete' EXIT

for config in "${configs[@]}"; do
  # shellcheck source=/dev/null
  source "$BENCH_DIR/configs/$config.env"
  for run in $(seq "$RUNS"); do
    out="$RESULTS/$config/run-$run"
    if grep -qs '"interrupted": false' "$out/metrics.json"; then
      echo "== $config run $run already done, skipping (delete $out to redo it)"
      continue
    fi
    for attempt in 1 2 3; do
      echo
      echo "== $config run $run (attempt $attempt)"
      rm -rf "$out"
      mkdir -p "$out"
      "$BENCH_DIR/cluster.sh" delete
      # A failed setup (for example nodes not Ready because the Mac slept)
      # is discarded and retried like a failed run.
      if "$BENCH_DIR/cluster.sh" create "$config" &&
         python3 "$BENCH_DIR/nodes.py" --kubeconfig "$BENCH_KUBECONFIG"; then
        setup_ok=1
      else
        setup_ok=0
      fi
      {
        echo "config: $config"
        echo "kwokctl: $(kwokctl --version)"
        kubectl --kubeconfig "$BENCH_KUBECONFIG" version | grep Server
        echo "feature gates: ${FEATURE_GATES:-none}"
        echo "workload mode: $WORKLOAD_MODE"
        echo "rate: $RATE Pods/s, seed: $SEED"
        echo "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      } > "$out/cluster.txt"
      # caffeinate keeps the Mac awake for the run (no-op elsewhere).
      keep_awake=()
      command -v caffeinate >/dev/null && keep_awake=(caffeinate -i)
      if [[ $setup_ok -eq 1 ]] && ${keep_awake[@]+"${keep_awake[@]}"} python3 "$BENCH_DIR/run.py" --kubeconfig "$BENCH_KUBECONFIG" \
          --mode "$WORKLOAD_MODE" --rate "$RATE" --seed "$SEED" --out "$out" &&
         grep -q '"interrupted": false' "$out/metrics.json"; then
        break
      fi
      discarded="$RESULTS/$config/discarded-$(date +%Y%m%d-%H%M%S)"
      mv "$out" "$discarded"
      echo "$config run $run attempt $attempt discarded: $discarded" | tee -a "$RESULTS/discarded.txt"
      if [[ $attempt -eq 3 ]]; then
        echo "giving up on $config run $run" >&2
        exit 1
      fi
    done
  done
done

python3 "$BENCH_DIR/summarize.py"
