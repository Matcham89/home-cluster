# Flux Operator Web UI with Authentik SSO

A complete guide to implementing Single Sign-On (SSO) for the Flux Operator Web UI using Authentik as the identity provider with Kubernetes Gateway API.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Implementation Steps](#implementation-steps)
  - [1. Authentik Configuration](#1-authentik-configuration)
  - [2. Secret Management](#2-secret-management)
  - [3. Flux Operator Configuration](#3-flux-operator-configuration)
  - [4. Gateway Configuration](#4-gateway-configuration)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [References](#references)

## Overview

This guide demonstrates how to secure the Flux Operator Web UI with OAuth2/OIDC authentication using Authentik as the identity provider. The solution uses:

- **Flux Operator**: GitOps operator with built-in web UI
- **Authentik**: Modern identity provider with OAuth2/OIDC support
- **Gateway API**: Kubernetes-native API for managing ingress traffic
- **External Secrets**: Bitwarden integration for secret management

## Architecture

```
┌─────────────────┐
│     User        │
└────────┬────────┘
         │ 1. Access https://flux.example.com
         ▼
┌─────────────────────┐
│  Gateway (Istio)    │ 2. Routes to Flux Web UI
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  Flux Operator      │ 3. Checks authentication
│  Web UI (Port 9080) │
└────────┬────────────┘
         │ 4. Not authenticated
         │
         ▼
┌─────────────────────┐
│     Authentik       │ 5. OAuth2 redirect
│  (Identity Provider)│ 6. User authenticates
└────────┬────────────┘
         │
         │ 7. Redirect back with token
         ▼
┌─────────────────────┐
│  Flux Web UI        │ 8. Validates token
│                     │ 9. Grants access
└─────────────────────┘
```

## Prerequisites

### Required Components

- **Kubernetes Cluster** (v1.25+)
- **Flux Operator** installed and operational
- **Authentik** instance (v2023.x or later)
- **Gateway API** implementation (Istio, Envoy Gateway, etc.)
- **External Secrets Operator** (optional, for secret management)
- **cert-manager** or TLS certificates for HTTPS

### Required Permissions

- Cluster admin access or permissions to:
  - Create secrets in `flux-system` namespace
  - Create ResourceSets, HTTPRoutes
  - Label namespaces
  - Manage Gateway resources

### DNS Configuration

- Domain pointing to your Gateway load balancer
- Example: `flux.example.com` → Gateway IP address

## Implementation Steps

### 1. Authentik Configuration

#### Create OAuth2/OIDC Application

1. Log into Authentik admin interface
2. Navigate to **Applications** → **Applications**
3. Click **Create** and configure:

**Basic Settings:**
- **Name**: `Flux Web UI`
- **Slug**: `flux-web-ui`
- **Provider**: Create new OAuth2/OpenID Provider

**Provider Configuration:**
- **Name**: `Flux Web UI Provider`
- **Authentication flow**: `default-authentication-flow`
- **Authorization flow**: `default-provider-authorization-explicit-consent`

**OAuth2 Settings:**
- **Client type**: `Confidential`
- **Client ID**: Generate or set custom (e.g., `flux-web-ui-client`)
- **Client Secret**: Generate and save securely
- **Redirect URIs**: `https://flux.example.com/oauth2/callback`
- **Signing Key**: `authentik Self-signed Certificate`

**Advanced Settings:**
- **Scopes**: `openid`, `profile`, `email`
- **Subject mode**: `Based on the User's hashed ID`
- **Include claims in id_token**: ✓ Enabled

4. Click **Create** and note down:
   - Client ID
   - Client Secret
   - Issuer URL (found in provider details, typically: `https://authentik.example.com/application/o/flux-web-ui/`)

#### Configure Group Mappings (Optional)

For RBAC integration:

1. Navigate to **Customisation** → **Property Mappings**
2. Create **Scope Mapping**:
   - **Name**: `Groups`
   - **Scope name**: `groups`
   - **Expression**:
     ```python
     return {
       "groups": [group.name for group in user.ak_groups.all()]
     }
     ```
3. Add this mapping to your OAuth2 provider's scopes

### 2. Secret Management

Choose one of the following methods to store OAuth2 credentials:

#### Option A: External Secrets (Recommended)

**2.1. Store credentials in Bitwarden Secrets Manager:**

Create two secrets in your Bitwarden organization:
- **Secret 1**: `flux-oauth-client-id`
  - Key: `client-id`
  - Value: `<your-client-id>`
- **Secret 2**: `flux-oauth-client-secret`
  - Key: `client-secret`
  - Value: `<your-client-secret>`

**2.2. Create ExternalSecret resource:**

Create `flux/apps/base/flux-system/flux-operator-web/externalsecret.yaml`:

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: flux-web-client
  namespace: flux-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: bitwarden-secretsmanager
    kind: ClusterSecretStore
  target:
    name: flux-web-client
    creationPolicy: Owner
  data:
    - secretKey: client-id
      remoteRef:
        key: "<bitwarden-secret-id-1>"
        property: client-id
    - secretKey: client-secret
      remoteRef:
        key: "<bitwarden-secret-id-2>"
        property: client-secret
```

#### Option B: Manual Kubernetes Secret

```bash
kubectl create secret generic flux-web-client \
  --from-literal=client-id='<your-client-id>' \
  --from-literal=client-secret='<your-client-secret>' \
  -n flux-system
```

### 3. Flux Operator Configuration

#### 3.1. Create ResourceSet

The ResourceSet manages the Flux Operator deployment with OAuth2 configuration.

Create `flux/apps/base/flux-system/flux-operator-web/flux-operator-config.yaml`:

```yaml
---
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  inputs:
    - domain: "example.com"  # Replace with your domain
  resources:
    # OCI Repository for Flux Operator Helm Chart
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: OCIRepository
      metadata:
        name: << inputs.provider.name >>
        namespace: << inputs.provider.namespace >>
      spec:
        interval: 30m
        url: oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator
        layerSelector:
          mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
          operation: copy
        ref:
          semver: '*'

    # Helm Release with OAuth2 Configuration
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      metadata:
        name: << inputs.provider.name >>
        namespace: << inputs.provider.namespace >>
      spec:
        interval: 30m
        releaseName: << inputs.provider.name >>
        serviceAccountName: << inputs.provider.name >>
        chartRef:
          kind: OCIRepository
          name: << inputs.provider.name >>
        values:
          web:
            config:
              baseURL: "https://flux.<< inputs.domain >>"
              authentication:
                type: OAuth2
                oauth2:
                  provider: OIDC
                  issuerURL: "https://authentik.example.com/application/o/flux-web-ui/"
            ingress:
              enabled: false  # Using Gateway API instead
        valuesFrom:
          - kind: Secret
            name: flux-web-client
            valuesKey: client-id
            targetPath: web.config.authentication.oauth2.clientID
          - kind: Secret
            name: flux-web-client
            valuesKey: client-secret
            targetPath: web.config.authentication.oauth2.clientSecret
```

**Key Configuration Points:**

| Field | Purpose | Example |
|-------|---------|---------|
| `inputs.domain` | Your base domain | `example.com` |
| `baseURL` | Full URL to Flux Web UI | `https://flux.example.com` |
| `issuerURL` | Authentik OIDC issuer endpoint | `https://authentik.example.com/application/o/flux-web-ui/` |
| `provider` | OAuth2 provider type | `OIDC` (generic OpenID Connect) |
| `valuesFrom` | Secret references for credentials | References `flux-web-client` secret |

**Template Variables Explained:**

- `<< inputs.domain >>` - Replaced with value from `spec.inputs[].domain`
- `<< inputs.provider.name >>` - Auto-generated from ResourceSet metadata name (`flux-operator`)
- `<< inputs.provider.namespace >>` - Auto-generated from ResourceSet metadata namespace (`flux-system`)

#### 3.2. Create HTTPRoute

Add to the same file or create separately:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: flux-web
  namespace: flux-system
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: istio-gateway  # Replace with your Gateway name
      namespace: istio-system  # Replace with your Gateway namespace
  hostnames:
    - "flux.example.com"  # Replace with your domain
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: flux-operator
          namespace: flux-system
          port: 9080
```

#### 3.3. Create Kustomization

Create `flux/apps/base/flux-system/flux-operator-web/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - externalsecret.yaml  # If using External Secrets
  - flux-operator-config.yaml
```

#### 3.4. Deploy via Flux

Create environment-specific Kustomization at `flux/apps/dev/flux-system/flux-operator-web/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system-flux-operator-web
  namespace: flux-system
spec:
  interval: 30m
  path: ./flux/apps/base/flux-system/flux-operator-web
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
```

Add this Kustomization to your environment's main kustomization file:

```yaml
# flux/apps/dev/flux-system/kustomization.yaml
resources:
  - ./flux-operator-web/ks.yaml
  # ... other resources
```

### 4. Gateway Configuration

#### 4.1. Enable Namespace Access

Your Gateway must allow HTTPRoutes from the `flux-system` namespace:

**Option A: Label-based Selection** (Recommended)

If your Gateway uses namespace selectors:

```bash
kubectl label namespace flux-system istio-gateway-access=true
```

Make this persistent by adding to your namespace infrastructure component:

```yaml
# flux/infra/namespace-privileged/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: not-used
  labels:
    istio-gateway-access: "true"
    # ... other labels
```

**Option B: Gateway Configuration**

Ensure your Gateway allows routes from `flux-system`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-gateway
  namespace: istio-system
spec:
  gatewayClassName: istio
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      hostname: '*.example.com'
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              istio-gateway-access: "true"
      tls:
        mode: Terminate
        certificateRefs:
          - name: tls-cert
```

#### 4.2. Verify Gateway Status

```bash
kubectl get gateway -n istio-system
kubectl get httproute -n flux-system
```

Expected output:
```
NAME          CLASS   ADDRESS         PROGRAMMED   AGE
istio-gateway istio   192.168.1.100   True         5d

NAME        HOSTNAMES              AGE
flux-web    ["flux.example.com"]   5m
```

## Verification

### 1. Check Resource Status

```bash
# ExternalSecret (if using)
kubectl get externalsecret flux-web-client -n flux-system
# Should show: READY=True, STATUS=SecretSynced

# Secret
kubectl get secret flux-web-client -n flux-system
kubectl get secret flux-web-client -n flux-system -o jsonpath='{.data}' | jq 'keys'
# Should show: ["client-id", "client-secret"]

# ResourceSet
kubectl get resourceset flux-operator -n flux-system
# Should show: READY=True

# HelmRelease
kubectl get helmrelease flux-operator -n flux-system
# Should show: READY=True, STATUS=Helm upgrade succeeded

# HTTPRoute
kubectl get httproute flux-web -n flux-system -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")]}'
# Should show: status=True, reason=Accepted
```

### 2. Check Pod Logs

```bash
kubectl logs -n flux-system deployment/flux-operator | grep -i auth
```

Expected log entry:
```json
{
  "level":"info",
  "msg":"authentication initialized successfully",
  "authProvider":"OAuth2/OIDC"
}
```

### 3. Test Web Access

```bash
curl -I https://flux.example.com
```

Expected response headers:
```
HTTP/2 200
set-cookie: auth-provider=eyJhdXRoZW50aWNhdGVkIjpmYWxzZSwicHJvdmlkZXIiOiJPSURDIiwidXJsIjoiaHR0cHM6Ly9mbHV4LmV4YW1wbGUuY29tL29hdXRoMi9hdXRob3JpemUifQ; Path=/; SameSite=Lax
```

### 4. Browser Test

1. Navigate to `https://flux.example.com`
2. You should be redirected to Authentik login page
3. Authenticate with your Authentik credentials
4. Upon successful authentication, you'll be redirected back to Flux Web UI
5. You should see the Flux dashboard

## Troubleshooting

### HTTPRoute Not Accepted

**Symptom:**
```bash
kubectl get httproute flux-web -n flux-system
# STATUS: NotAllowedByListeners
```

**Solution:**
```bash
# Add required label to namespace
kubectl label namespace flux-system istio-gateway-access=true

# Verify Gateway allows the namespace
kubectl get gateway <gateway-name> -n <gateway-namespace> -o yaml | grep -A 10 allowedRoutes
```

### Authentication Loop

**Symptom:** Continuously redirected between Flux UI and Authentik

**Possible Causes:**

1. **Incorrect Redirect URI:**
   - Verify in Authentik: `https://flux.example.com/oauth2/callback`
   - Must match exactly (including trailing slash)

2. **Client Secret Mismatch:**
   ```bash
   # Check secret content
   kubectl get secret flux-web-client -n flux-system -o jsonpath='{.data.client-secret}' | base64 -d
   ```

3. **Issuer URL Incorrect:**
   - Verify it ends with trailing slash: `https://authentik.example.com/application/o/flux-web-ui/`
   - Check Authentik provider details for exact URL

### Secret Not Found

**Symptom:**
```
Error: secret "flux-web-client" not found
```

**Solution:**

```bash
# Check ExternalSecret status
kubectl describe externalsecret flux-web-client -n flux-system

# Check ClusterSecretStore
kubectl get clustersecretstore

# Manual secret creation as fallback
kubectl create secret generic flux-web-client \
  --from-literal=client-id='<client-id>' \
  --from-literal=client-secret='<client-secret>' \
  -n flux-system
```

### TLS Certificate Issues

**Symptom:** Browser shows certificate errors

**Solution:**

Ensure your Gateway has valid TLS certificates:

```bash
kubectl get secret <cert-secret> -n <gateway-namespace>

# If using cert-manager
kubectl get certificate -n <gateway-namespace>
```

### Web UI Not Loading

**Symptom:** 503 Service Unavailable

**Checks:**

```bash
# Verify pod is running
kubectl get pods -n flux-system -l app.kubernetes.io/name=flux-operator

# Check service
kubectl get svc flux-operator -n flux-system

# Test service directly
kubectl port-forward -n flux-system svc/flux-operator 9080:9080
curl http://localhost:9080/healthz

# Check HTTPRoute backend references
kubectl get httproute flux-web -n flux-system -o yaml | grep -A 5 backendRefs
```

## Key Learnings

### ResourceSet vs HelmRelease

The ResourceSet provides several advantages over standalone HelmRelease:

1. **Templating**: Variables like `<< inputs.domain >>` for environment-agnostic configs
2. **Multi-Resource**: Deploy HelmRelease, OCIRepository, and HTTPRoute in one file
3. **GitOps Adoption**: Can take over existing Helm installations
4. **Auto-naming**: `<< inputs.provider.name >>` generates consistent resource names

### Why OIDC Provider Type?

Even though Authentik is the identity provider, we use `provider: OIDC` (not `provider: authentik`) because:
- Flux Operator uses generic OIDC implementation
- Works with any OIDC-compliant provider
- More portable across different identity providers

### Gateway API vs Ingress

This setup uses Gateway API instead of Ingress because:
- More expressive routing capabilities
- Better multi-tenancy support
- Native support in modern service meshes (Istio, Linkerd)
- Graduated to GA in Kubernetes 1.29

## References

- [Flux Operator Documentation](https://fluxoperator.dev/)
- [Flux Operator SSO with Keycloak](https://fluxoperator.dev/docs/web-ui/sso-keycloak/)
- [Authentik OAuth2 Provider](https://goauthentik.io/docs/providers/oauth2/)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
- [External Secrets Operator](https://external-secrets.io/)
- [ResourceSet CRD Specification](https://fluxoperator.dev/docs/crds/resourceset/)

## License

This documentation is provided as-is under MIT License.

---

**Author**: [Your Name]
**Date**: 2025-12-19
**Flux Operator Version**: v0.37.1
**Kubernetes Version**: v1.29+
