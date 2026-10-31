# GitOps with Argo CD

KubeSchedulerConfiguration's admission policies, the Kyverno install that runs them and the cluster-wide objects the demos rely on are managed by Argo CD from this repository. The `main` branch is the source of truth: Argo CD applies what is in Git and puts back anything changed by hand.

## Why GitOps on a GPU platform

The scheduler configuration decides where GPU jobs run, but the policies decide which jobs are admitted at all. A policy that is deleted, edited by hand or left behind on one cluster changes who can use the GPUs, and nothing in the scheduler shows it. With GitOps:

- **Every change is a commit.** Raising the per-Pod GPU limit or adding a PriorityClass goes through review, and `git log` shows who changed what and when.
- **Drift is corrected.** A policy deleted or edited with `kubectl` is restored from Git within seconds (see [Results](#results)).
- **Clusters stay identical.** Each cluster runs Argo CD pointed at the same branch, so a new GPU cluster gets the same policies, PriorityClasses and namespaces as the others.
- **Changes can be tried on a branch.** One Application can be pointed at a branch, checked, and pointed back.

## How it works

### Version

Argo CD is installed from the Helm chart `argo/argo-cd` version **10.11.6** (Argo CD **v3.5.6**), pinned in [`scripts/install-argocd.sh`](../scripts/install-argocd.sh), with values in [`deploy/argocd/values.yaml`](../deploy/argocd/values.yaml). The [tested Kubernetes versions table](https://argo-cd.readthedocs.io/en/stable/operator-manual/tested-kubernetes-versions/) lists Argo CD 3.5 as tested on Kubernetes v1.33 to v1.36. Argo CD 3.6 adds v1.37, but at the time of writing it was only available as a release candidate (v3.6.0-rc4), so the latest stable release was chosen. On this v1.37.0 cluster Argo CD is therefore untested upstream, as Kyverno is (see [policy-enforcement.md](policy-enforcement.md#version)). Every result below was checked on the running cluster.

The values file only changes what this setup needs:

- Dex (SSO), notifications and the ApplicationSet controller are turned off; the setup logs in as the local `admin` user and uses plain Applications.
- A health check for `Application` resources is added to `argocd-cm`. Argo CD does not assess the health of Applications by default, so without it the root Application would not wait for Kyverno to be Healthy before syncing the policies.

### App of apps

```
gitops/
├── root.yaml            # Application "root": applied once by hand, points at gitops/apps/
└── apps/
    ├── kyverno.yaml     # wave 0: Kyverno chart 3.9.2 + deploy/kyverno/values.yaml
    ├── platform.yaml    # wave 0: PriorityClasses and the ml-team-a namespace
    └── policies.yaml    # wave 1: everything in policies/
```

`root` watches `gitops/apps/` on `main` and creates the three child Applications. Adding a file to `gitops/apps/` adds an Application, and deleting it removes the Application and its objects. Every Application tracks `main` and syncs automatically with `prune` (objects removed from Git are deleted) and `selfHeal` (objects changed in the cluster are put back).

| Application | Source | Wave | Sync options |
|---|---|---|---|
| `kyverno` | Helm chart `kyverno/kyverno` 3.9.2, values from this repository | 0 | `CreateNamespace=true`, `ServerSideApply=true` |
| `platform` | `manifests/priority/priorityclasses.yaml`, `manifests/policy/namespace.yaml` | 0 | none |
| `policies` | `policies/` | 1 | none |

**Sync waves.** The ClusterPolicy CRD and Kyverno's admission webhooks come from the Kyverno chart, so the policies cannot be applied before it. `policies` is in wave 1. With the Application health check above, `root` only starts wave 1 once `kyverno` is Synced and Healthy, which means its Deployments are available.

**Multiple sources.** `kyverno` takes the chart from the Kyverno Helm repository and the values file from this repository (`ref: values`, `$values/deploy/kyverno/values.yaml`). The same values file is used by `scripts/install-kyverno.sh`, so both install paths configure Kyverno identically.

**Sync options, and why only these.**

- `ServerSideApply=true` on `kyverno`: the chart renders about 5.8 MB of manifests, including 22 CRDs. Client-side apply stores the whole object in the `kubectl.kubernetes.io/last-applied-configuration` annotation, and the largest Kyverno CRDs (`clusterpolicies.kyverno.io`, `policies.kyverno.io`) are about 640 KiB, over the 256 KiB annotation limit. Kyverno's [Argo CD notes](https://kyverno.io/docs/installation/platform-notes/) also recommend server-side apply.
- `CreateNamespace=true` on `kyverno`: the chart does not create its own namespace.
- None on `platform` and `policies`: they are small objects that client-side apply handles.
- Kyverno's notes also suggest server-side diff and ignoring differences in aggregated ClusterRoles. All four Applications stayed Synced for several hours after the takeover without either, so neither was added.

**Helm hooks.** Argo CD runs Helm hooks as its own hooks: Kyverno's `post-upgrade` Job `kyverno-migrate-resources` runs after each sync of `kyverno` (it finished with "stored version is already up to date"), and the chart's `test` Pods are skipped.

### What is managed, and what is not

| Managed by Argo CD | Not managed |
|---|---|
| Kyverno (chart and values) | Argo CD itself (installed by `scripts/install-argocd.sh`) |
| The four ClusterPolicies in `policies/` | `kind-config.yaml` and the feature gates |
| PriorityClasses `gpu-high`, `gpu-low` | `scheduler-config.yaml` (the kube-scheduler configuration) |
| Namespace `ml-team-a` with `gpu-policy=enforced` | Fake GPUs (`scripts/setup-fake-gpus.sh`) |
| | Demo workloads, PodGroups, Workloads and the benchmark |

Argo CD manages objects stored through the Kubernetes API. The scheduler configuration and the feature gates are not API objects: they are files and flags given to the kube-scheduler and kube-apiserver when kind creates the control plane, before there is an API for Argo CD to talk to. Changing them means restarting or recreating control-plane components. In production this layer belongs to cluster-lifecycle tools such as Cluster API, which create and upgrade the control plane, while Argo CD manages what runs on it. The fake GPUs are a node status patch for the kind cluster only. Demo and benchmark workloads are short-lived and created by the scripts; managing them would make Argo CD prune or restore them in the middle of a demo.

### Taking over a cluster installed by hand

sched-dev already had Kyverno (installed by `scripts/install-kyverno.sh`), the four policies, the PriorityClasses and the namespace before Argo CD was added. Removing them and letting Argo CD recreate them would leave a window with no admission policies. Instead, Argo CD adopts them in place:

- The `kyverno` Application uses the same Helm release name (`kyverno`), namespace and values, so it renders objects with the same names, and Argo CD applies over the existing ones.
- The policies and platform objects in Git are the files that were applied by hand, so Argo CD's apply changes nothing except adding its tracking annotation (`argocd.argoproj.io/tracking-id`).
- After the Applications are Synced, `scripts/bootstrap-gitops.sh` deletes Helm's release record for Kyverno (the `sh.helm.release.v1.kyverno.*` Secrets). The objects stay; only Helm's bookkeeping goes, so there is one owner and a later `helm upgrade` cannot fight Argo CD.

Argo CD 3.x tracks objects with an annotation rather than the `app.kubernetes.io/instance` label, so it does not clash with the label the Kyverno chart sets.

`scripts/install-kyverno.sh` remains the non-GitOps path, for a cluster without Argo CD. Do not run it on a cluster where Argo CD manages Kyverno: it would create a new Helm release over objects Argo CD owns.

## Reproduce

The repository must be public, because Argo CD reads it from GitHub without credentials. No credentials are stored in the repository.

```bash
# Kyverno installed or not, policies applied or not: both work.
./scripts/bootstrap-gitops.sh
kubectl -n argocd get applications
```

The script installs or upgrades Argo CD, applies `gitops/root.yaml`, waits until all four Applications are Synced and Healthy, removes the old Helm release record for Kyverno if there is one, and lists the policies. It is safe to re-run.

To open the Argo CD UI, port-forward the server and log in as `admin`:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# in another terminal: print the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

Then open https://localhost:8080 (the certificate is self-signed).

### Self-heal demo

```bash
./scripts/gitops-demo.sh
```

The script deletes the `require-team-label` ClusterPolicy and times how long until it exists again and is Ready. It then changes the validate message of `max-gpus-per-pod` with `kubectl patch` and times how long until the message from Git is back.

### Branch demo

These steps try a change from a branch on one Application without touching `main`.

1. Turn off automated sync on `root`. Otherwise its `selfHeal` would immediately set the `policies` Application back to `main`:
   ```bash
   kubectl -n argocd patch application root --type=json \
     -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
   ```
2. Create a branch, change a policy and push the branch:
   ```bash
   git checkout -b gitops-demo
   # add metadata.annotations: kubeschedulerconfiguration.io/gitops-demo: "from-branch"
   # to policies/require-team-label.yaml
   git commit -am "Annotate require-team-label for the GitOps branch demo"
   git push -u origin gitops-demo
   ```
3. Point `policies` at the branch and watch the annotation appear:
   ```bash
   kubectl -n argocd patch application policies --type=merge \
     -p '{"spec":{"source":{"targetRevision":"gitops-demo"}}}'
   kubectl get clusterpolicy require-team-label -o jsonpath='{.metadata.annotations}'
   ```
4. Point it back at `main`, check the annotation is gone, and turn automated sync on `root` back on:
   ```bash
   kubectl -n argocd patch application policies --type=merge \
     -p '{"spec":{"source":{"targetRevision":"main"}}}'
   kubectl apply -f gitops/root.yaml
   ```
5. Delete the branch locally and on GitHub:
   ```bash
   git checkout main
   git branch -D gitops-demo
   git push origin --delete gitops-demo
   ```

## Results

All results are from sched-dev (Kubernetes v1.37.0, one control plane and three workers).

**Bootstrap and takeover.** On the cluster with Kyverno, the policies and the platform objects already installed by hand, all four Applications were Synced and Healthy 19 seconds after `root` was applied. The UIDs of the four ClusterPolicies, the four Kyverno Deployments, the ClusterPolicy CRD, both PriorityClasses and the `ml-team-a` namespace were the same before and after, and the Kyverno controller Pods were not restarted: the objects were adopted, not recreated. The only new Pod was the `kyverno-migrate-resources` hook Job. A loop listing the ClusterPolicies once a second from before `root` was applied until two minutes after (124 samples) showed 4 policies, all Ready, in every sample.

**Self-heal.** On a clean run of `scripts/gitops-demo.sh`:

| Change by hand | Restored after |
|---|---|
| `kubectl delete clusterpolicy require-team-label` | 1 s (new UID, Ready) |
| `kubectl patch` of the `max-gpus-per-pod` message | 1 s |

Each change was put back by a partial sync of only the changed policy. Repeated runs were slower, because Argo CD backs off between self-heals of the same Git revision (see [Differences from expectations](#differences-from-expectations)).

**Branch.** After `policies` was pointed at `gitops-demo`, the annotation from the branch was on the ClusterPolicy 2 seconds later, and `policies` reported the branch commit as Synced and Healthy. While it pointed at the branch, `root` showed OutOfSync, because the `policies` Application no longer matched Git. Pointed back at `main`, the annotation was gone 1 second later. After automated sync on `root` was turned back on, all four Applications were Synced and Healthy on the `main` commit. The branch was deleted locally and on GitHub, and `main` was unchanged.

### No regressions

With Argo CD managing Kyverno, the policies and the platform objects, the earlier demos gave the same results as before:

- `scripts/policy-demo.sh`: all nine examples matched the expected result (three policies rejected the bad Pods and allowed the good ones, the `require-team-label` example was allowed outside `ml-team-a`, and `default-rack-topology` added `topology.rack` only when no constraint was set).
- `scripts/gang-demo.sh partial gang`: the 4-pod trainer gang stayed fully Pending with 0 GPUs held, and its PodGroup reported Unschedulable.
- `scripts/topology-demo.sh with-topology`: all 4 Pods of the job were placed in one rack.
- `scripts/priority-demo.sh preemption`: the `gpu-high` gang preempted all 4 low-priority Pods and ran with 8 GPUs, both when the low-priority Pods were a gang and when they were plain Pods.
- `manifests/gpu-test.yaml`: the six 1-GPU Pods were packed 4/2/0 across the three workers.

### Differences from expectations

**Self-heal backs off.** The first self-heal runs restored changes in 1–2 seconds, but later runs took 17 s, 53 s and then 300 s. The Application's `autoHealAttemptsCount` had reached 8. Argo CD waits between self-heal attempts on the same Git revision, starting at 2 seconds and multiplying by 3 per attempt up to 300 seconds (`--self-heal-backoff-timeout-seconds`, `--self-heal-backoff-factor`, `--self-heal-backoff-cap-seconds` on the application controller). The count resets when Argo CD syncs a new revision; after the branch demo synced two new revisions, the next run was back to 1 second. The defaults were kept: the backoff stops Argo CD from fighting another controller in a tight loop, and on a real platform hand edits are rare.

**Self-heal syncs are not in the sync history.** Self-heal applies only the out-of-sync objects. Argo CD does not add these partial syncs to `.status.history`, so the demo script shows the Application's events instead.

## Limitations

- **Untested Kubernetes version.** Argo CD 3.5 and Kyverno 1.19 are not tested upstream on Kubernetes v1.37.
- **New commits are picked up by polling.** Without a webhook from GitHub, Argo CD checks the repository every 120 seconds plus up to 60 seconds of jitter, so a push to `main` can take up to 3 minutes to reach the cluster. Changes to an Application's own spec, as in the branch demo, are picked up at once.
- **Public repository only.** Argo CD reads the repository without credentials. A private repository would need a repository Secret created outside Git.
- **Local admin user.** SSO is turned off and the initial admin password is in a cluster Secret. A shared cluster would use SSO and delete `argocd-initial-admin-secret`.
- **Bootstrap is manual.** Argo CD and `gitops/root.yaml` are installed by `scripts/bootstrap-gitops.sh`; Argo CD does not manage itself.
- **Branch tests need the root paused.** Pointing one Application at a branch requires turning off automated sync on `root`, and turning it back on afterwards.
