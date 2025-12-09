# Zitadel Operator Setup

This directory contains the Zitadel deployment configuration with PostgreSQL backend using CloudNativePG (CNPG).

## Prerequisites

- CNPG cluster running in `cnpg-system` namespace
- PostgreSQL database `home-cluster` with owner `zitadel`
- External Secrets Operator configured with Bitwarden

## Required Secrets

The following secrets must exist in the `zitadel` namespace (managed by External Secrets):

1. **zitadel-masterkey** - Zitadel encryption masterkey
2. **zitadel-db-password** - PostgreSQL password for `zitadel` user

## Components

### 1. certs-job.yaml
Creates self-signed certificates for PostgreSQL client authentication.

**Note:** Currently not used as we're using password authentication with `sslmode=require` instead of client certificates.

### 2. database-setup-job.yaml
**IMPORTANT:** This job must run before Zitadel pods start.

Performs PostgreSQL setup:
- Grants `CREATEROLE` and `CREATEDB` privileges to `zitadel` user
- Creates `cache` schema (PostgreSQL 18 compatibility workaround)
- Creates cache tables without `UNLOGGED` keyword (fixes Zitadel migration 34_add_cache_schema)
- Copies CNPG certificates to zitadel namespace

### 3. helmrelease.yaml
Deploys Zitadel using the official Helm chart.

**Configuration:**
- External domain: `pg-secure.127.0.0.1.sslip.io`
- Database: CNPG cluster at `postgres-rw.cnpg-system.svc.cluster.local:5432`
- SSL mode: `require` (encrypted connection, password auth)
- No client certificates (removed due to compatibility issues)

## Known Issues & Workarounds

### PostgreSQL 18 Compatibility

Zitadel migration `34_add_cache_schema` fails on PostgreSQL 15+ because it attempts to create unlogged partitioned tables, which are not supported.

**Solution:** The `database-setup-job.yaml` creates the cache schema and tables manually without the `UNLOGGED` keyword.

### SSL/TLS Configuration

Initially configured with `verify-full` SSL mode and client certificates, but this caused issues:
- `tls: unsupported certificate` errors
- Client certificate format incompatible with PostgreSQL expectations

**Solution:** Changed to `sslmode=require` which encrypts the connection but uses password authentication instead of client certificates.

## Deployment Order

The Flux kustomization has a dependency on `cnpg-cluster` to ensure PostgreSQL is ready before deploying Zitadel.

Recommended order:
1. CNPG cluster creates database
2. `database-setup-job` runs (grants permissions, creates cache schema)
3. `certs-job` runs (creates certificates, currently optional)
4. Zitadel HelmRelease deploys

## Troubleshooting

### Pod crashes with "permission denied to create role"
The `zitadel` user needs `CREATEROLE` privilege. Run the database-setup-job or manually:
```sql
ALTER USER zitadel WITH CREATEROLE CREATEDB;
```

### Pod crashes with "schema cache does not exist"
The cache schema wasn't created. Run the database-setup-job or manually create:
```sql
CREATE SCHEMA IF NOT EXISTS cache;
GRANT ALL ON SCHEMA cache TO zitadel;
-- See database-setup-job.yaml for full table creation
```

### HelmRelease fails with "could not resolve Secret chart values reference"
Check that external secrets are synced:
```bash
kubectl get externalsecret -n zitadel
```

### TLS certificate errors
Ensure you're using `sslmode=require` not `verify-full`. The helmrelease.yaml should NOT have `dbSslCaCrtSecret`, `dbSslAdminCrtSecret`, or `dbSslUserCrtSecret` fields.

## Accessing Zitadel

- Console: `https://pg-secure.127.0.0.1.sslip.io:443/ui/console`
- Health Check: `https://pg-secure.127.0.0.1.sslip.io:443/debug/healthz`

## Future Improvements

1. Consider using CNPG's managed database initialization instead of a separate job
2. Switch to using CNPG's certificate management for client auth once compatibility is resolved
3. Contribute a fix to Zitadel for PostgreSQL 15+ unlogged partitioned table issue
