#!/usr/bin/env bash
# Create or delete the sched-bench KWOK cluster for the KubeSchedulerConfiguration
# benchmark. It is separate from the sched-dev kind cluster, and its kubeconfig
# is written to its own file, so ~/.kube/config and its current context are
# left alone.
#
# Usage:
#   benchmarks/cluster.sh create <config>   # config: a file name in benchmarks/configs/, without .env
#   benchmarks/cluster.sh delete
#
# The kubeconfig path is $BENCH_KUBECONFIG (default ~/.kwok/sched-bench.kubeconfig).
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
BENCH_DIR="$REPO_ROOT/benchmarks"
CLUSTER=sched-bench
BENCH_KUBECONFIG="${BENCH_KUBECONFIG:-$HOME/.kwok/sched-bench.kubeconfig}"

case "${1:-}" in
  create)
    config="${2:-}"
    env_file="$BENCH_DIR/configs/$config.env"
    [[ -f "$env_file" ]] || { echo "unknown config: $config" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$env_file"

    # Every config gets the same client connection limits. Without them the
    # scheduler uses 50 qps / 100 burst, because kube-scheduler ignores
    # kwokctl's --kube-api-qps flag when --config is set.
    rendered="$(mktemp -d)/scheduler-config.yaml"
    sed 's|^  kubeconfig: /etc/kubernetes/scheduler.conf$|&\n  qps: 5000\n  burst: 10000|' \
      "$REPO_ROOT/$SCHEDULER_CONFIG" > "$rendered"
    grep -q '^  qps: 5000$' "$rendered" || { echo "could not add qps to $SCHEDULER_CONFIG" >&2; exit 1; }

    args=(--name "$CLUSTER" --config "$BENCH_DIR/kwokctl.yaml" --kubeconfig "$BENCH_KUBECONFIG"
          --kube-scheduler-config "$rendered")
    [[ -n "$FEATURE_GATES" ]] && args+=(--kube-feature-gates "$FEATURE_GATES")
    [[ -n "$RUNTIME_CONFIG" ]] && args+=(--kube-runtime-config "$RUNTIME_CONFIG")

    if kwokctl get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
      echo "cluster $CLUSTER already exists; run '$0 delete' first" >&2
      exit 1
    fi
    echo "== Creating $CLUSTER for config $config (gates: ${FEATURE_GATES:-none})"
    kwokctl create cluster "${args[@]}" >/dev/null 2>&1 ||
      { echo "kwokctl create cluster failed; rerun with the same arguments to see why" >&2; exit 1; }
    for _ in $(seq 60); do
      kubectl --kubeconfig "$BENCH_KUBECONFIG" get --raw /readyz >/dev/null 2>&1 && break
      sleep 1
    done
    kubectl --kubeconfig "$BENCH_KUBECONFIG" version | grep Server
    ;;
  delete)
    if kwokctl get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
      kwokctl delete cluster --name "$CLUSTER" --kubeconfig "$BENCH_KUBECONFIG" >/dev/null 2>&1
      echo "== Deleted $CLUSTER"
    fi
    rm -f "$BENCH_KUBECONFIG"
    ;;
  *)
    echo "usage: $0 create <config> | delete" >&2
    exit 1
    ;;
esac
