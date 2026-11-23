# Longhorn volume backup and recovery posture

Scope: what this repository says about backing up and recovering Longhorn volumes. Based only on files in the repo (as of `main`). Nothing was checked against the live cluster.

**Summary:** the repo configures Longhorn for *resilience* (auto-salvage, replica rebuild throttling, pod recreation). It does **not** configure any Longhorn *backup*. Replication and re-attachment are not backups.

## Configured

### Longhorn deployment
- Longhorn is installed by Flux via HelmRelease, chart `1.12.1`: `flux/apps/base/longhorn-system/helmrelease.yaml`. Flux Kustomization: `flux/apps/dev/longhorn-system/operator/ks.yaml`.
- Namespace `longhorn-system` uses the privileged namespace template (`flux/CLAUDE.md:116`).

### Failure-recovery settings (`defaultSettings` in the HelmRelease)
Added after the 2026-07-16 power outage, per the in-file comments:
- `autoSalvage: true` - re-attach volumes whose replicas failed after an unexpected node loss.
- `autoDeletePodWhenVolumeDetachedUnexpectedly: true` - recreate the workload pod so the volume re-attaches.
- `replicaReplenishmentWaitInterval: 600` - wait 10 min before rebuilding replicas after a node returns.
- `concurrentReplicaRebuildPerNodeLimit: 2` - bounds concurrent rebuilds.
- `nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod`.
- `storageOverProvisioningPercentage: 200` - note: allows scheduling 2x physical capacity, which reduces headroom for replica rebuilds.
- `guaranteedInstanceManagerCPU: 5`.

### Workloads on Longhorn (`storageClass: longhorn`)
| Workload | Size | File |
|---|---|---|
| CNPG `postgres-cluster` (2 instances, streaming replica) | 10Gi | `flux/apps/base/databases/cluster/cluster.yaml:11,18-20` |
| Qdrant | 10Gi | `flux/apps/base/qdrant/qdrant/helmrelease.yaml:45-49` |
| SeaweedFS (storage) master data | 1Gi | `flux/apps/base/storage/seaweedfs/helmrelease.yaml:36-41` (plus further `longhorn` volumes at lines 60 and 81) |
| SeaweedFS (monitoring, backs Loki/Tempo S3) | see file | `flux/apps/base/monitoring/seaweedfs/helmrelease.yaml:44,55,68` |
| Loki | 20Gi | `flux/apps/base/monitoring/grafana/loki.yaml:171,177` |
| rustfs (substrate snapshot store) | RWO Longhorn volume | comment at `flux/apps/base/substrate/substrate-operator/helmrelease.yaml:53` |

The Flux Kustomization for SeaweedFS (storage) depends on `longhorn` (`flux/apps/dev/storage/seaweedfs/ks.yaml:22`).

Not on Longhorn: Grafana persistence is disabled (`kube-prometheus-stack.yaml:155-156`); Tempo persistence is disabled (`tempo.yaml:369-370`).

## Not configured / not found
Searched `flux/`, `docs/`, `bootstrap/`, `tmp/`, `scripts/` for `RecurringJob`, `backupTarget`, `backup-target`, `VolumeSnapshot`, `backupstore`, `barmanObjectStore`, `ScheduledBackup`:
- No Longhorn `RecurringJob` (no scheduled snapshots or backups).
- No Longhorn backup target (S3/NFS) or backup-target secret; no `backupTarget` value in the HelmRelease.
- No `VolumeSnapshot` / `VolumeSnapshotClass` resources.
- No CNPG backup: the `postgres-cluster` has no `backup` / `barmanObjectStore` section and no `ScheduledBackup`. The 2nd instance is streaming replication only. (The `cnpg-agent` can *inspect* Backup/ScheduledBackup resources, `flux/apps/base/kagent/agents/cnpg-agent.yaml:21,29`, but none are defined here.)
- No off-cluster copy of any volume data.
- No restore test or restore runbook for Longhorn volumes.
- No defined RPO/RTO or retention policy.
- Longhorn default replica count is not set in the repo (chart default applies; not asserted here).
- `flux/apps/dev/monitoring/README.md:257-263` lists data "to backup" (dashboards, Alertmanager config, Prometheus, Loki) but only as a list of considerations; it describes no mechanism and still mentions MinIO although SeaweedFS is used.

## Could not verify (outside the repo)
- Whether any RecurringJobs, backup targets or snapshots were created manually in the Longhorn UI (the UI is exposed via `flux/apps/base/ingress/httproutes/longhorn.yaml`) - such state is not in Git.
- Actual replica count per volume and node/disk placement (chart/StorageClass defaults, live state).
- Longhorn settings changed at runtime that differ from the HelmRelease.
- Backups made outside the repo (e.g. Talos/etcd backups, cloud or NAS copies; the `talos-config` repo is referenced in `docs/` but is not part of this repo).
- Whether recovery actually works: nothing in the repo evidences a tested restore.

## Gaps worth a decision (not changes made here)
1. Configure a Longhorn backup target and a `RecurringJob` for backups of Qdrant, rustfs, SeaweedFS volumes.
2. Use CNPG-native backups (object store + `ScheduledBackup`) for PostgreSQL instead of relying on volume replicas.
3. Decide per workload whether the data is reproducible (Loki/Tempo telemetry) or needs backup.
4. Define RPO/RTO and run a restore test.
