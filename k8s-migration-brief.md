# PostgreSQL & SeaweedFS → Kubernetes Migration Brief

## Context

This machine (`192.168.1.100`) runs PostgreSQL 18 natively and SeaweedFS via Docker Compose. The target is:
- **PostgreSQL** → [CloudNativePG](https://cloudnative-pg.io/) operator
- **SeaweedFS** → SeaweedFS Kubernetes operator/manifests

The K8s cluster already exists and has network access to `192.168.1.100`. There are draft Kubernetes manifests already in `/home/chris/homelab/docker/` (k8s-external-services.yaml, etc.) from a prior connectivity exploration.

---

## PostgreSQL

**Version:** 18 (main cluster)

**Data directory:** `/mnt/data2/postgres` (non-default — mounted separately, likely on a large disk)

**Config:** `/etc/postgresql/18/main/postgresql.conf`

Tuning parameters to carry forward into CloudNativePG:
```
max_connections = 200
shared_buffers = 1GB
effective_cache_size = 3GB
maintenance_work_mem = 256MB
wal_buffers = 16MB
checkpoint_completion_target = 0.9
min_wal_size = 1GB
max_wal_size = 4GB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200
work_mem = 5MB
autovacuum_worker_slots = 16
```

**Timezone:** `America/Edmonton`

**SSL:** Enabled (currently using snakeoil certs — CloudNativePG manages its own TLS automatically)

**Authentication:** `pg_hba.conf` at `/etc/postgresql/18/main/pg_hba.conf` — could not be read without root. Access patterns observed:
- Connections accepted from `192.168.1.191` (Rundeck) and `192.168.1.192` (home cluster nodes)
- `listen_addresses = '*'` — accepts connections from all interfaces

**Databases:** `homelab` (primary app database)

**Credentials (currently in `/home/chris/homelab/docker/.env`):**
```
POSTGRES_USER=postgres
POSTGRES_PASSWORD=ADjPoHKClqRbkZyyeTdd8sqAJG2okeAtib6DK4yZVow=
POSTGRES_DB=homelab
```

**Monitoring:** `prometheuscommunity/postgres-exporter` container connects to `172.20.0.1:5432/homelab` and exports on port 9187. Needs to be redeployed pointing at the CloudNativePG service endpoint.

**CloudNativePG migration notes:**
- Use a `Cluster` resource with PostgreSQL 18
- The postgresql.conf tuning above should go into `spec.postgresql.parameters`
- PVC storage class should point to storage backed by or migrated from `/mnt/data2/postgres`
- CloudNativePG can bootstrap a new cluster from an external instance using `spec.bootstrap.initdb` or `spec.bootstrap.recovery` from a backup

---

## SeaweedFS

**Version:** 3.80

**Image:** `chrislusf/seaweedfs:3.80`

**Deployment:** Docker Compose at `/home/chris/homelab/docker/docker-compose.yaml`

**Data on disk:** `/mnt/data2/seaweedfs/`
- `master/` — 20K
- `filer/` — 82MB (filer metadata/SQLite)
- `volume/` — 50GB (actual object data)

### Components

| Component | Container | Ports | Command flags |
|-----------|-----------|-------|---------------|
| Master | `seaweedfs-master` | 9333, 19333, 9324 (metrics) | `-ip=seaweedfs-master -ip.bind=0.0.0.0 -metricsPort=9324` |
| Volume | `seaweedfs-volume` | 8080, 18080, 9327 (metrics) | `-mserver=seaweedfs-master:9333 -dir=/data -max=100 -metricsPort=9327` |
| Filer | `seaweedfs-filer` | 8888, 18888, 9328 (metrics) | `-master=seaweedfs-master:9333 -metricsPort=9328` |
| S3 gateway | `seaweedfs-s3` | 8333, 9329 (metrics) | `-filer=seaweedfs-filer:8888 -config=/etc/seaweedfs/s3.json -metricsPort=9329` |

### Resource limits (Docker Compose → K8s requests/limits baseline)

| Component | RAM limit | RAM reservation | CPU limit | CPU reservation |
|-----------|-----------|-----------------|-----------|-----------------|
| Master | 512Mi | 256Mi | 1000m | 500m |
| Volume | 1Gi | 512Mi | 500m | 250m |
| Filer | 1Gi | 512Mi | 1000m | 500m |
| S3 | (not specified) | — | — | — |

### S3 credentials (currently in `/home/chris/homelab/docker/s3-config.json`)

```json
{
  "identities": [
    {
      "name": "default",
      "credentials": [
        {
          "accessKey": "HAw6mY8pRqLCSKs6Z29AUOI4VwLuQX8a",
          "secretKey": "kirmxT6mAI9BJf3rXxxVMT1RWd01urwAv3ER8n2uEpM="
        }
      ],
      "actions": ["Admin", "Read", "Write"]
    }
  ]
}
```

**SeaweedFS Kubernetes migration notes:**
- The 50GB volume data in `/mnt/data2/seaweedfs/volume/` needs to be either migrated to a PVC or synced to new volume servers after K8s deployment via SeaweedFS replication
- The filer store (LevelDB/SQLite in `/mnt/data2/seaweedfs/filer/`) must be preserved or migrated
- Master metadata in `/mnt/data2/seaweedfs/master/` is small and must be migrated
- All four components (master, volume, filer, s3) need separate K8s Deployments/StatefulSets
- The S3 config JSON should become a Kubernetes Secret mounted into the s3 container
- Prometheus scrape endpoints are already exposed on dedicated metric ports

---

## Network / Access Patterns

Clients connecting from the K8s cluster:
- Rundeck at `192.168.1.191` uses PostgreSQL on port `5432`
- Home cluster nodes at `192.168.1.191`, `192.168.1.192` use PostgreSQL
- S3 gateway (`8333`) and filer (`8888`) are the primary SeaweedFS client endpoints

The existing draft manifests at `/home/chris/homelab/docker/k8s-external-services.yaml` can serve as reference for the current "point K8s at external host" approach, which will be superseded by this migration.

---

## Open Questions for the K8s Agent

1. **Storage class** — what storage class is available in the cluster for PVCs? (local-path, NFS, Longhorn, Ceph, etc.) This affects how the 50GB SeaweedFS volume data and Postgres data get provisioned.
2. **Migration strategy for Postgres** — live streaming replica from current host, or scheduled downtime + pg_dump restore?
3. **SeaweedFS data migration** — can the K8s nodes mount the same `/mnt/data2` NFS/local path, or does the data need to be copied?

---

> **Credentials note:** All credentials above are currently stored in plaintext. During the K8s migration, wrap them in Kubernetes Secrets (or use an external secrets manager like External Secrets Operator). Do not embed them in ConfigMaps or manifests.
