#!/usr/bin/env bash
# Self-heal demo for KubeSchedulerConfiguration, run against a cluster
# bootstrapped with scripts/bootstrap-gitops.sh. Changes Argo CD-managed
# Kyverno policies by hand and shows Argo CD putting them back from Git.
#
# Usage:
#   ./scripts/gitops-demo.sh
#       1. Deletes the require-team-label ClusterPolicy and times how long it
#          takes until it exists again and is Ready.
#       2. Changes the validate message of max-gpus-per-pod and times how long
#          it takes until the message from Git is back.
#
# Argo CD backs off between self-heals of the same Git revision (2s, then x3
# per attempt, at most 300s; reset when a new revision is synced), so running
# this repeatedly without a new commit makes each run slower.
set -euo pipefail

DELETE_POLICY="require-team-label"
PATCH_POLICY="max-gpus-per-pod"
TIMEOUT=300

elapsed() { echo "$(( $(date +%s) - $1 ))"; }

# kyverno.io/v1 ClusterPolicy prints a deprecation warning on every request;
# keep it out of the demo output.
policy() { kubectl get clusterpolicy "$@" 2>/dev/null; }
message() { policy "$PATCH_POLICY" -o jsonpath='{.spec.rules[0].validate.message}'; }

app_status() {
  kubectl -n argocd get application policies \
    -o jsonpath='{.status.sync.status}/{.status.health.status}'
}

echo "== Before"
kubectl -n argocd get application policies
policy

echo
echo "== 1. Deleting ClusterPolicy $DELETE_POLICY"
old_uid=$(policy "$DELETE_POLICY" -o jsonpath='{.metadata.uid}')
kubectl delete clusterpolicy "$DELETE_POLICY" --wait=true 2>/dev/null
start=$(date +%s)
until [[ "$(policy "$DELETE_POLICY" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]]; do
  if (( $(elapsed "$start") > TIMEOUT )); then
    echo "not restored after ${TIMEOUT}s" >&2; exit 1
  fi
  sleep 1
done
new_uid=$(policy "$DELETE_POLICY" -o jsonpath='{.metadata.uid}')
echo "Restored and Ready after $(elapsed "$start")s (UID $old_uid -> $new_uid)"
policy "$DELETE_POLICY"

echo
echo "== 2. Changing the message of ClusterPolicy $PATCH_POLICY"
git_msg=$(message)
echo "Message from Git: $git_msg"
kubectl patch clusterpolicy "$PATCH_POLICY" --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/validate/message","value":"Changed by hand"}]' 2>/dev/null
start=$(date +%s)
echo "Message now:      $(message)"
until [[ "$(message)" == "$git_msg" ]]; do
  if (( $(elapsed "$start") > TIMEOUT )); then
    echo "not reverted after ${TIMEOUT}s" >&2; exit 1
  fi
  sleep 1
done
echo "Reverted after $(elapsed "$start")s"
echo "Message now:      $(message)"

echo
echo "== Waiting for Application policies to be Synced and Healthy"
start=$(date +%s)
until [[ "$(app_status)" == "Synced/Healthy" ]]; do
  if (( $(elapsed "$start") > TIMEOUT )); then
    echo "not Synced/Healthy after ${TIMEOUT}s" >&2; exit 1
  fi
  sleep 2
done

echo
echo "== After"
kubectl -n argocd get application policies
policy
echo
# Self-heal syncs only the out-of-sync resources (a partial sync), which Argo CD
# does not add to the Application's sync history, so show its events instead.
echo "== Recent events of Application policies"
kubectl -n argocd get events --field-selector involvedObject.name=policies \
  --sort-by=.lastTimestamp | tail -8
