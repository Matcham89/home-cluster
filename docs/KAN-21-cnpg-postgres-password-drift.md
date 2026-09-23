# Troubleshooting: CNPG Postgres Superuser Password Drift After Power Loss

**Date:** 2026-09-23
**Affects:** CNPG `postgres-cluster` — superuser (`postgres`) role password
**Symptom:** Apps (authentik, n8n, etc.) fail authentication: `password authentication failed for user "postgres"`
**Cluster:** Talos v1.12.2, Kubernetes v1.35.0, Flux CD

---

## Failure Mode

After a full power loss and cluster restart, apps that connect as the CNPG
`postgres` superuser may fail with authentication errors. This happens because:

1. The CNPG `postgres-cluster` restarts when the cluster comes back up.
2. The Kubernetes Secret `postgres-superuser` persists across the restart with
   an **unchanged `resourceVersion`** — ESO refreshes it from Bitwarden with the
   same value, so neither the data nor the metadata change.
3. **CNPG only reconciles the superuser role password when the Secret's
   `resourceVersion` changes.** If the live `postgres` role password had drifted
   previously (e.g. from bootstrap inconsistency, a manual `ALTER ROLE`, or a
   partial CNPG recovery), the drift never self-heals.
4. The `postgres-superuser` Secret was also historically of type `Opaque` — CNPG
   expects `kubernetes.io/basic-auth` for the reload trigger to function.

**Result:** The role password in the running database differs from the Secret
value. Apps that authenticate as `postgres` get connection failures and
CrashLoopBackOff.

---

## Immediate Recovery

Re-sync the live `postgres` role password to match the Secret value:

```bash
# 1. Get the pod name of the CNPG primary instance
POD=$(kubectl -n databases get pods -l postgresql=postgres-cluster \
  -o jsonpath='{.items[?(@.metadata.labels.role=="primary")].metadata.name}')

# 2. Read the expected password from the Secret
SECRET_PASSWORD=$(kubectl -n databases get secret postgres-superuser \
  -o jsonpath='{.data.password}' | base64 --decode)

# 3. Exec into the pod and connect via the peer-auth socket (no password needed)
kubectl -n databases exec "$POD" -c postgres -- \
  psql -U postgres -c "ALTER ROLE postgres WITH PASSWORD '${SECRET_PASSWORD}';"
```

After running this, apps should reconnect on their next retry. Restart any pods
that are still in CrashLoopBackOff:

```bash
kubectl -n authentik rollout restart deployment/authentik-operator-server
kubectl -n n8n rollout restart deployment/n8n
```

---

## Durable Prevention (Already Deployed)

The long-term fix, already applied, is to avoid relying on the superuser
password at all:

- **CNPG `managed.roles`** — authentik, n8n, and agentdesktop each have their
  own dedicated database role (non-superuser, with `LOGIN`) declared in the
  CNPG cluster spec under `spec.managed.roles`.
- **`passwordSecret` with `cnpg.io/reload: "true"`** — each role references a
  `kubernetes.io/basic-auth` Secret. When the Secret data changes, CNPG
  automatically reconciles the role password in the database.
- **App ExternalSecrets** point to per-role Bitwarden items, not the shared
  superuser secret.

Because CNPG continuously reconciles managed roles every time their source
Secret changes (tracking `resourceVersion` natively, unlike the superuser path),
these roles are immune to the drift described above.

If you add a new app that needs a Postgres database, add it as a managed role in
`flux/apps/base/databases/cluster/cluster.yaml` rather than reusing the
superuser credentials.

---

## Verification

To confirm no apps are still using the superuser role:

```bash
kubectl -n databases exec deployment/postgres-cluster-1 -c postgres -- \
  psql -U postgres -c "SELECT usename, application_name, client_addr \
  FROM pg_stat_activity WHERE usename = 'postgres' AND pid <> pg_backend_pid();"
```

Zero rows returned (other than your own session) means clean migration.

---

## References

- `flux/apps/base/databases/cluster/cluster.yaml` — CNPG cluster spec with
  managed roles
- `flux/apps/base/databases/secrets/` — ExternalSecret definitions for each
  managed role and the superuser secret
- [CNPG Documentation: Managed Roles](https://cloudnative-pg.io/documentation/current/managed_roles/)
- [KAN-19: Document CNPG backup posture and restore paths](docs/KAN-19-cnpg-backup-posture.md)