#!/usr/bin/env bash
# Kyverno policy demo for KubeSchedulerConfiguration. Needs Kyverno
# (scripts/install-kyverno.sh), the policies in policies/ and the ml-team-a
# namespace from manifests/policy/namespace.yaml.
#
# Validate examples are applied with `kubectl apply --dry-run=server`, so
# admission runs but nothing is stored. The mutate examples are then really
# created to show the stored PodGroup spec, and deleted again.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
EX="$REPO_ROOT/manifests/policy/examples"
NS="ml-team-a"
RESULTS=""

# Drop Kyverno's ClusterPolicy deprecation warning from kubectl output.
quiet() { grep -v '^Warning: kyverno.io/v1 ClusterPolicy is deprecated' || true; }

add_row() { RESULTS="$RESULTS$1|$2|$3|$4"$'\n'; }

# check_validate POLICY FILE EXPECTED [NAMESPACE]
check_validate() {
  local policy="$1" file="$2" expected="$3" ns="${4:-$NS}" out actual
  echo "== $policy: $(basename "$file") in $ns"
  if out=$(sed "s/namespace: $NS/namespace: $ns/" "$file" |
      kubectl apply --dry-run=server -f - 2>&1 | quiet); then
    actual="allowed"
  else
    # Kyverno puts the rule's message on the last line: "  rule: 'message'".
    actual="denied: $(tail -1 <<<"$out" | sed -E "s/^ *[^:]+: //; s/^'//; s/^validation error: //; s/ rule [^ ]+ failed at path .*//; s/'$//")"
  fi
  echo "$out"
  add_row "$policy" "$(basename "$file" .yaml)${4:+ (ns $4)}" "$expected" "$actual"
}

# check_mutate FILE EXPECTED
check_mutate() {
  local file="$1" expected="$2" name before after actual
  name=$(kubectl create --dry-run=client -f "$file" -o jsonpath='{.metadata.name}')
  before=$(kubectl create --dry-run=client -f "$file" -o jsonpath='{.spec.schedulingConstraints}')
  echo "== default-rack-topology: $(basename "$file") in $NS"
  echo "-- server dry run, spec returned by admission:"
  kubectl apply --dry-run=server -f "$file" -o jsonpath='{.spec}' 2>&1 | quiet; echo
  echo "-- created for real, stored spec:"
  kubectl apply -f "$file" 2>&1 | quiet
  kubectl -n "$NS" get podgroups.scheduling.k8s.io "$name" -o jsonpath='{.spec}'; echo
  after=$(kubectl -n "$NS" get podgroups.scheduling.k8s.io "$name" -o jsonpath='{.spec.schedulingConstraints}')
  if [[ "$before" == "$after" ]]; then
    actual="unchanged: schedulingConstraints $after"
  else
    actual="mutated: schedulingConstraints $after"
  fi
  kubectl -n "$NS" delete podgroups.scheduling.k8s.io "$name" --wait=true >/dev/null
  add_row "default-rack-topology" "$(basename "$file" .yaml)" "$expected" "$actual"
}

echo "== Cleaning up previous policy demo objects"
kubectl -n "$NS" delete pods,podgroups.scheduling.k8s.io -l app.kubernetes.io/part-of=policy-demo \
  --ignore-not-found --wait=true

check_validate require-team-label            "$EX/require-team-label-pass.yaml"            allowed
check_validate require-team-label            "$EX/require-team-label-fail.yaml"            denied
check_validate max-gpus-per-pod              "$EX/max-gpus-per-pod-pass.yaml"              allowed
check_validate max-gpus-per-pod              "$EX/max-gpus-per-pod-fail.yaml"              denied
check_validate distributed-jobs-require-gang "$EX/distributed-jobs-require-gang-pass.yaml" allowed
check_validate distributed-jobs-require-gang "$EX/distributed-jobs-require-gang-fail.yaml" denied
# Scope check: the same failing Pod in an unlabelled namespace is not checked.
check_validate require-team-label            "$EX/require-team-label-fail.yaml"            allowed default
check_mutate "$EX/default-rack-topology-unchanged.yaml" unchanged
check_mutate "$EX/default-rack-topology-mutated.yaml"   mutated

echo
echo "== Results"
{
  echo "POLICY|EXAMPLE|EXPECTED|ACTUAL"
  printf '%s' "$RESULTS"
} | column -t -s '|'
