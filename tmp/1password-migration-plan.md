# Migration Plan: Bitwarden ESO → 1Password Operator

## Overview

Replace all `ExternalSecret` (ESO + Bitwarden) resources with `OnePasswordItem` CRDs managed by
the 1Password Operator. The operator is already deployed and running in the `1password` namespace
with `autoRestart: true`.

---

## OnePasswordItem Reference

```yaml
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: SECRET_NAME  # Name to use for the created Kubernetes Secret
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/ITEM"
  # ITEM  — ID or title of the 1Password item
```

### How field names map to Kubernetes secret keys

The **field label** in a 1Password item becomes the **key** in the resulting Kubernetes secret.
The field value becomes the secret value.

For example, a 1Password item with these fields:

| 1Password field label | 1Password field value |
|-----------------------|-----------------------|
| `username`            | `admin`               |
| `password`            | `hunter2`             |
| `ANTHROPIC_API_KEY`   | `sk-ant-...`          |

Produces a Kubernetes secret with keys `username`, `password`, and `ANTHROPIC_API_KEY`.

> The section name (e.g. "Login", "API Credentials") does not matter — only the field label does.

---

## Phase 1 — 1Password Vault Structure

The vault ID is `wlgvy5jij6zg2sb25nju4nyjnm`. Create the following items inside it.

**Field labels must match exactly** — they become the keys in the resulting K8s secret.

---

### Item: `openai`
Used by: `kagent-openai` (field: `OPENAI_API_KEY`) and `openai-secret` (field: `Authorization`)
Since both need the same value but different key names, store both fields with the same value.

| Field name        | Value                    |
|-------------------|--------------------------|
| `OPENAI_API_KEY`  | your OpenAI API key      |
| `Authorization`   | same OpenAI API key      |

---

### Item: `anthropic`
Used by: `kagent-anthropic` (field: `ANTHROPIC_API_KEY`) and `anthropic-secret` (field: `Authorization`)

| Field name          | Value                    |
|---------------------|--------------------------|
| `ANTHROPIC_API_KEY` | your Anthropic API key   |
| `Authorization`     | same Anthropic API key   |

---

### Item: `google`
Used by: `kagent-google` (field: `GOOGLE_API_KEY`) and `google-secret` (field: `Authorization`)

| Field name      | Value                  |
|-----------------|------------------------|
| `GOOGLE_API_KEY`| your Google API key    |
| `Authorization` | same Google API key    |

---

### Item: `github-pat`
Used by: `kagent-github`

| Field name   | Value            |
|--------------|------------------|
| `GITHUB_PAT` | your GitHub PAT  |

---

### Item: `github-webhook`
Used by: `github-webhook-secret`

| Field name              | Value                   |
|-------------------------|-------------------------|
| `GITHUB_WEBHOOK_SECRET` | your webhook secret     |

---

### Item: `callmebot`
Used by: `callmebot-env-vars` in `kagent`

| Field label        | Value                     |
|--------------------|---------------------------|
| `CALLMEBOT_APIKEY` | your CallMeBot API key    |
| `CALLMEBOT_PHONE`  | your phone number         |

---

### Item: `yt-kmcp`
Used by: `yt-kmcp-env-vars` in `kagent`

| Field label           | Value                              |
|-----------------------|------------------------------------|
| `TRANSCRIPT_LANGS`    | transcript language(s)             |
| `TRANSCRIPT_MIN_LEN`  | minimum transcript length          |
| `YTDLP_TIMEOUT`       | yt-dlp timeout value               |

---

### Item: `cloudflare-tunnel`
Used by: `tunnel-token` in both `monitoring` and `istio-system` namespaces.
Both reference the same value — a single 1Password item can back multiple `OnePasswordItem` CRDs.

| Field name | Value                   |
|------------|-------------------------|
| `token`    | your Cloudflare tunnel token |

---

### Item: `cloudflare-certmanager`
Used by: `cloudflare-api-token` in `kube-ops`

| Field name  | Value                         |
|-------------|-------------------------------|
| `api-token` | your Cloudflare API token     |

> Note: This may be the same token as `cloudflare-tunnel`. If so, you can use a single item with
> both field names (`token` and `api-token`), or keep them separate for clarity.

---

### Item: `s3-credentials`
Used by: `s3-credentials` in `monitoring`
Currently split across 2 Bitwarden items — consolidate into one.

| Field name              | Value                      |
|-------------------------|----------------------------|
| `AWS_ACCESS_KEY_ID`     | your S3 access key ID      |
| `AWS_SECRET_ACCESS_KEY` | your S3 secret access key  |

---

### Item: `monitoring-oauth`
Used by: `auth-generic-oauth-secret` in `monitoring`
Currently split across 2 Bitwarden items. Store clean values (no surrounding quotes).

| Field name      | Value                        |
|-----------------|------------------------------|
| `client_id`     | Grafana OAuth client ID      |
| `client_secret` | Grafana OAuth client secret  |

---

### Item: `kagent-oauth2-proxy`
Used by: `kagent-oauth2-proxy` in `kagent`
Currently split across 3 Bitwarden items — consolidate into one.

| Field name      | Value                  |
|-----------------|------------------------|
| `client-id`     | OAuth2 proxy client ID |
| `client-secret` | OAuth2 proxy client secret |
| `cookie-secret` | OAuth2 proxy cookie secret |

---

### Item: `flux-web-client`
Used by: `flux-web-client` in `flux-system`
Currently split across 2 Bitwarden items — consolidate into one.

| Field name      | Value                    |
|-----------------|--------------------------|
| `client-id`     | Flux UI OAuth client ID  |
| `client-secret` | Flux UI OAuth client secret |

---

### Item: `kiali`
Used by: `kiali` in `istio-system`

| Field name    | Value               |
|---------------|---------------------|
| `oidc-secret` | Kiali OIDC secret   |

---

### Item: `rundeck-postgres`
Used by: `rundeck-postgres-credentials` in `rundeck`

| Field label | Value                      |
|-------------|----------------------------|
| `username`  | Rundeck DB username        |
| `password`  | Rundeck DB password        |

---

### Item: `n8n-postgres`
Used by: `n8n-postgres-credentials` in `n8n`

| Field label | Value              |
|-------------|--------------------|
| `username`  | n8n DB username    |
| `password`  | n8n DB password    |

---

### Item: `authentik-postgres`
Used by: `authentik-postgres-credentials` in `authentik`

| Field label | Value                   |
|-------------|-------------------------|
| `username`  | Authentik DB username   |
| `password`  | Authentik DB password   |

> Note: Bitwarden had n8n and Authentik sharing the same item (`c45c2bb1-...`). Verify whether
> this is intentional. If they share credentials, you can point both `OnePasswordItem` CRDs at
> the same 1Password item instead of creating two separate ones.

---

## Phase 2 — Add 1Password ClusterSecretStore (optional bridge)

If you want to migrate gradually using ESO with 1Password as the backend before switching to the
operator CRDs, you can add a `ClusterSecretStore` for 1Password Connect. Otherwise skip this and
go straight to Phase 3.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: 1password
spec:
  provider:
    onepassword:
      connectHost: http://onepassword-connect.1password.svc.cluster.local:8080
      vaults:
        home-cluster: 1
      auth:
        secretRef:
          connectTokenSecretRef:
            name: onepassword-token
            namespace: 1password
            key: token
```

---

## Phase 3 — Replace ExternalSecret Manifests

Replace each file as follows. The `OnePasswordItem` CRD creates a K8s secret with the same name
as the CR, containing all fields from the referenced 1Password item.

### `apps/base/kagent/secrets/kagent.yaml`

Replace all 7 ExternalSecrets with:

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: kagent-openai
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/openai"
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: kagent-anthropic
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/anthropic"
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: kagent-github
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/github-pat"
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: kagent-google
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/google"
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: github-webhook-secret
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/github-webhook"
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: callmebot-env-vars
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/callmebot"
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: yt-kmcp-env-vars
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/yt-kmcp"
```

---

### `apps/base/kgateway-system/secrets/anthropic-secret.yaml`

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: anthropic-secret
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/anthropic"
```

---

### `apps/base/kgateway-system/secrets/google-secret.yaml`

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: google-secret
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/google"
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: openai-secret
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/openai"
```

---

### `apps/base/monitoring/kube-prometheus-stack/secrets/seaweedFS-s3-credentials.yaml`

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: s3-credentials
  namespace: monitoring
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/s3-credentials"
```

---

### `apps/base/monitoring/kube-prometheus-stack/secrets/cloudflare.yaml`

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: tunnel-token
  namespace: monitoring
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/cloudflare-tunnel"
```

---

### `apps/base/monitoring/kube-prometheus-stack/secrets/authentik.yaml`

No templating needed — store clean values (no quotes) directly in 1Password.

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: auth-generic-oauth-secret
  namespace: monitoring
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/monitoring-oauth"
```

---

### `apps/base/istio-system/istio/secrets/cloudflare.yaml`

> Note: The current manifest has `deletionPolicy: Retain`. The 1Password operator has no
> equivalent — the K8s secret will be deleted when the `OnePasswordItem` is deleted. If you need
> to protect this secret, manually remove the label `operator.1password.io/item-path` from the
> secret before deleting the `OnePasswordItem`, which will orphan it.

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: tunnel-token
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/cloudflare-tunnel"
```

---

### `apps/base/kiali/secrets/oidc.yaml`

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: kiali
  namespace: istio-system
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/kiali"
```

---

### `apps/base/kagent/oauth2-proxy/externalsecret.yaml`

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: kagent-oauth2-proxy
  namespace: kagent
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/kagent-oauth2-proxy"
```

---

### `apps/base/flux-system/flux-operator/externalsecret.yaml`

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: flux-web-client
  namespace: flux-system
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/flux-web-client"
```

---

### `apps/base/rundeck/secrets/external-secret.yaml`

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: rundeck-postgres-credentials
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/rundeck-postgres"
```

---

### `apps/base/n8n/secrets/external-secret.yaml`

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: n8n-postgres-credentials
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/n8n-postgres"
```

---

### `apps/base/authentik/secrets/postgres-creds.yaml`

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: authentik-postgres-credentials
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/authentik-postgres"
```

---

### `apps/dev/kube-ops/cert-manager/secrets/cloudflare-api.yaml`

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: cloudflare-api-token
  namespace: kube-ops
spec:
  itemPath: "vaults/wlgvy5jij6zg2sb25nju4nyjnm/items/cloudflare-certmanager"
```

---

## Phase 4 — Decommission ESO + Bitwarden

Once all secrets are confirmed syncing from 1Password:

1. Delete the `bitwarden-secretsmanager` ClusterSecretStore
2. Remove ESO from the cluster:
   - Delete `apps/dev/kube-ops/external-secrets/operator/ks.yaml`
   - Delete `apps/dev/kube-ops/external-secrets/store/ks.yaml`
   - Delete the base manifests in `apps/base/kube-ops/external-secrets/`
3. Remove the Bitwarden ESO provider secret (if any)

---

## Notes & Gotchas

- **`autoRestart: true`** is already enabled on the operator — any update to a 1Password item
  will automatically restart pods that use the synced secret. No Reloader needed.
- **Vault/item name casing** in `itemPath` must match exactly what's in 1Password.
- **The operator syncs on a polling interval** (default 10min). Force a sync by deleting and
  recreating the `OnePasswordItem`.
- **n8n + Authentik share a Bitwarden item** — confirm whether this is intentional before
  creating separate 1Password items.
- **`deletionPolicy: Retain`** on the istio tunnel-token has no equivalent — handle manually
  if secret preservation is required.
- The `kagent` namespace does not appear in `OnePasswordItem` metadata for the kagent secrets
  file — the namespace is inherited from the Kustomization's `targetNamespace`. Verify this
  is still the case after the switch.
