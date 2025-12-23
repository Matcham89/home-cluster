# How to Secure Flux Web UI with Authentik SSO and Kubernetes Gateway API

**TL;DR:** Lock down your Flux dashboard with OAuth2/OIDC authentication using Authentik, External Secrets, and Gateway API. No more exposed management UIs in production.

---

## Why This Matters

Picture this: Your Flux Web UI is managing production workloads across multiple clusters. One misconfiguration, one leaked URL, and suddenly anyone can view (or worse, manipulate) your entire GitOps pipeline.

**The problem?** Most guides show you how to *expose* Flux, but not how to *secure* it properly.

**The solution?** A modern authentication stack that gives you:
- ✅ **Single Sign-On** via OIDC (no shared passwords)
- ✅ **Secrets managed externally** (Bitwarden + External Secrets Operator)
- ✅ **Cloud-native routing** with Gateway API instead of legacy Ingress
- ✅ **Production-grade security** out of the box

By the end of this guide, you'll have a fully authenticated Flux dashboard that integrates with your existing identity provider.

---

## Prerequisites

Before we begin, make sure you have:

- **A Kubernetes cluster** (1.25+) with Gateway API CRDs installed
- **Flux Operator** deployed ([installation guide](https://fluxcd.io/flux/installation/))
- **Authentik** running (self-hosted or cloud) - [docs here](https://docs.goauthentik.io/)
- **External Secrets Operator** installed ([quickstart](https://external-secrets.io/latest/introduction/getting-started/))
- **A Gateway controller** (I'm using Istio, but Envoy Gateway or others work too)
- **DNS configured** for your domain (e.g., `flux.example.com`)

> **Not using Bitwarden?** You can adapt this guide for any secret backend that External Secrets supports (AWS Secrets Manager, HashiCorp Vault, etc.)

---

## Architecture: The 30,000-Foot View

Here's what we're building:
```
┌─────────────┐
│   Browser   │
└──────┬──────┘
       │ 1. Request: flux.example.com
       ▼
┌─────────────────────┐
│  Gateway API (Istio)│
│  HTTPRoute          │
└──────┬──────────────┘
       │ 2. Route to flux-operator:9080
       ▼
┌─────────────────────┐      ┌──────────────────┐
│  Flux Web UI        │◄─────┤  External Secret │
│  (OAuth2 enabled)   │      │  (from Bitwarden)│
└──────┬──────────────┘      └──────────────────┘
       │ 3. OAuth redirect
       ▼
┌─────────────────────┐
│    Authentik IdP    │
│  (OIDC Provider)    │
└─────────────────────┘
```

**The flow:**
1. User hits `flux.example.com` → Gateway API routes to Flux pod
2. Flux sees no auth cookie → redirects to Authentik login
3. User authenticates → Authentik sends them back with OAuth token
4. Flux validates token → serves the dashboard

---

## Step 1: Configure Authentik (Your Identity Provider)

Authentik needs to know that Flux exists as a trusted application. Think of this as registering Flux in your "identity passport system."

### 1.1 Create the OAuth2 Application

1. Navigate to **Applications → Providers** in Authentik
2. Click **Create** and select **OAuth2/OpenID Provider**
3. Fill in the details:

| Field | Value | Why |
|-------|-------|-----|
| **Name** | `Flux Web UI` | Human-readable identifier |
| **Client Type** | `Confidential` | Requires client secret (more secure) |
| **Redirect URI** | `https://flux.example.com/oauth2/callback` | Where Authentik sends users after login |
| **Client ID** | (auto-generated) | You'll need this for Flux config |
| **Client Secret** | (auto-generated) | Store this securely! |

4. Under **Advanced Settings**, note the **OpenID Configuration URL**:
```
   https://authentik.example.com/application/o/flux-web-ui/
```

### 1.2 Save Your Credentials

You'll need three pieces of information:
- **Client ID**: `abc123...`
- **Client Secret**: `supersecret456...`
- **Issuer URL**: `https://authentik.example.com/application/o/flux-web-ui/`

**🔒 Security Note:** Never commit these to Git! We'll handle them properly in the next step.

---

## Step 2: Store Credentials in Bitwarden + External Secrets

Hardcoding secrets in Git is the #1 GitOps anti-pattern. Instead, we'll use **External Secrets Operator** to pull credentials from Bitwarden at runtime.

### 2.1 Add Secrets to Bitwarden

1. In Bitwarden (or your Secrets Manager instance), create two new secrets:
   - `flux-web-client-id` → paste your Client ID
   - `flux-web-client-secret` → paste your Client Secret

2. Note the secret UUIDs for each (you'll see them in the Bitwarden UI)

### 2.2 Create the ExternalSecret Resource
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: flux-web-client
  namespace: flux-system
  annotations:
    # Optional: Document what this secret is for
    description: "OAuth2 credentials for Flux Web UI authentication"
spec:
  # Refresh every hour in case credentials rotate
  refreshInterval: 1h
  
  # Reference our Bitwarden SecretStore
  secretStoreRef:
    name: bitwarden-secretsmanager
    kind: ClusterSecretStore
  
  # The Kubernetes Secret that will be created
  target:
    name: flux-web-client
    creationPolicy: Owner
  
  # Map Bitwarden secrets to K8s secret keys
  data:
    - secretKey: client-id
      remoteRef:
        key: "<your-bitwarden-client-id-uuid>"
    
    - secretKey: client-secret
      remoteRef:
        key: "<your-bitwarden-client-secret-uuid>"
```

**Apply it:**
```bash
kubectl apply -f flux-web-externalsecret.yaml

# Verify the secret was created
kubectl get secret flux-web-client -n flux-system
```

> **💡 Pro Tip:** If you're just testing locally, you can create a standard Secret manually:
> ```bash
> kubectl create secret generic flux-web-client \
>   --from-literal=client-id=your-client-id \
>   --from-literal=client-secret=your-client-secret \
>   -n flux-system
> ```

---

## Step 3: Configure Flux Operator with OAuth2

Now for the main event. We'll use a **FluxInstance** (if using Flux Operator) or modify your existing Flux HelmRelease to enable OAuth2.

### 3.1 The Complete Configuration
```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  # ... your existing Flux config ...
  
  distribution:
    # Enable the Web UI component
    components:
      - web-ui
    
    version: "2.x"
  
  # Web UI specific configuration
  values:
    web:
      # Base configuration
      config:
        # CRITICAL: Must match your actual domain
        baseURL: "https://flux.example.com"
        
        # Enable OAuth2 authentication
        authentication:
          type: OAuth2
          oauth2:
            provider: OIDC  # Generic OIDC provider (Authentik speaks OIDC)
            
            # This is the OpenID Configuration URL from Authentik
            issuerURL: "https://authentik.example.com/application/o/flux-web-ui/"
            
            # Optional: Request specific scopes
            scopes:
              - openid
              - profile
              - email
      
      # Disable built-in Ingress (we're using Gateway API instead)
      ingress:
        enabled: false
    
    # Pull OAuth2 credentials from our ExternalSecret
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

### 3.2 What's Happening Here?

- **`baseURL`**: Where users will access Flux (must match your HTTPRoute hostname)
- **`issuerURL`**: Tells Flux where to validate OAuth tokens
- **`valuesFrom`**: Injects secrets from Kubernetes Secret into Helm values at runtime
- **`ingress.enabled: false`**: We're using Gateway API, so we don't need the default Ingress

---

## Step 4: Route Traffic with Gateway API

Gateway API is the modern replacement for Ingress, with better separation of concerns and more powerful routing capabilities.

### 4.1 Ensure Namespace Access

First, label your namespace so the Gateway can route to it:
```bash
kubectl label namespace flux-system istio-gateway-access=true
```

### 4.2 Create the HTTPRoute
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: flux-web
  namespace: flux-system
spec:
  # Which Gateway should handle this route
  parentRefs:
    - name: istio-gateway      # Your Gateway name
      namespace: istio-system  # Gateway namespace
  
  # What hostname(s) this route responds to
  hostnames:
    - "flux.example.com"
  
  # Routing rules
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: "/"
      
      # Where to send the traffic
      backendRefs:
        - name: flux-operator    # Service name
          port: 9080             # Flux Web UI port
          weight: 100
```

### 4.3 Apply and Verify
```bash
# Apply the HTTPRoute
kubectl apply -f flux-httproute.yaml

# Check the route status
kubectl get httproute flux-web -n flux-system -o yaml
```

Look for `status.parents[].conditions` with `type: Accepted` and `status: True`.

---

## Verification Checklist

Let's make sure everything is wired up correctly before we test in a browser.

| Component | Command | Success Indicator |
|-----------|---------|-------------------|
| **ExternalSecret** | `kubectl get externalsecret flux-web-client -n flux-system` | `SecretSynced: True` |
| **K8s Secret** | `kubectl get secret flux-web-client -n flux-system` | `Data: 2` (client-id, client-secret) |
| **Flux Instance** | `kubectl get fluxinstance flux -n flux-system` | `Ready: True` |
| **Web UI Pod** | `kubectl get pods -n flux-system \| grep web` | Pod running |
| **HTTPRoute** | `kubectl get httproute flux-web -n flux-system` | `Accepted: True` |

### Test the Full Flow

1. Open your browser to `https://flux.example.com`
2. **Expected:** You should be immediately redirected to Authentik's login page
3. Log in with your Authentik credentials
4. **Expected:** You're redirected back to `https://flux.example.com/oauth2/callback`
5. **Expected:** You land on the Flux Web UI dashboard, fully authenticated!

---

## Troubleshooting Guide

Things not working? Here are the most common issues and fixes:

### Issue: Redirect Loop (Keep bouncing between Flux and Authentik)

**Causes:**
- ❌ Redirect URI mismatch in Authentik
- ❌ `baseURL` in Flux config doesn't match actual URL
- ❌ Missing `/oauth2/callback` path in Authentik redirect URI

**Fix:**
```bash
# Check Flux's configured callback URL
kubectl get fluxinstance flux -n flux-system -o jsonpath='{.spec.values.web.config.baseURL}'

# Should output: https://flux.example.com
# Authentik redirect URI must be: https://flux.example.com/oauth2/callback
```

### Issue: "Unable to retrieve OpenID configuration"

**Causes:**
- ❌ Wrong `issuerURL` in Flux config
- ❌ Authentik not reachable from inside the cluster
- ❌ Network policy blocking egress

**Fix:**
```bash
# Test if Flux pod can reach Authentik
kubectl exec -n flux-system deployment/flux-operator-web -- \
  curl -k https://authentik.example.com/application/o/flux-web-ui/.well-known/openid-configuration

# Should return JSON with OAuth2 endpoints
```

### Issue: HTTPRoute shows "Accepted: False"

**Causes:**
- ❌ Gateway can't access the namespace
- ❌ Wrong Gateway name/namespace in `parentRefs`
- ❌ Service doesn't exist or wrong port

**Fix:**
```bash
# Verify Gateway exists
kubectl get gateway -A

# Check Gateway's allowed routes
kubectl get gateway istio-gateway -n istio-system -o yaml | grep -A 10 allowedRoutes

# Ensure service exists
kubectl get svc flux-operator -n flux-system
```

### Issue: "Client authentication failed"

**Causes:**
- ❌ Client secret mismatch
- ❌ ExternalSecret not syncing properly

**Fix:**
```bash
# Check if secret has data
kubectl get secret flux-web-client -n flux-system -o jsonpath='{.data}'

# Compare with Authentik
# Decode the secret
kubectl get secret flux-web-client -n flux-system -o jsonpath='{.data.client-id}' | base64 -d
```

---

## Going Further: Advanced Configurations

### Option 1: Add Authorization Rules

Want to restrict access to specific users or groups? Add this to your Flux config:
```yaml
web:
  config:
    authentication:
      oauth2:
        # ... existing config ...
        
        # Only allow users in "platform-team" group
        allowedGroups:
          - platform-team
```

### Option 2: Enable RBAC in Flux

Flux Web UI supports Kubernetes RBAC. Create a `RoleBinding` to control what authenticated users can do:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: flux-web-viewers
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view  # Read-only access
subjects:
  - kind: Group
    name: platform-team  # From your OIDC claims
    apiGroup: rbac.authorization.k8s.io
```

### Option 3: Add Rate Limiting

Protect against brute force attempts with Gateway API rate limiting:
```yaml
# (Istio example - syntax varies by Gateway implementation)
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: BackendTrafficPolicy
metadata:
  name: flux-rate-limit
  namespace: flux-system
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: flux-web
  
  rateLimits:
    - match:
        path: /oauth2/callback
      limit: 10      # requests
      window: 1m     # per minute
```

---

## Key Takeaways

You've just built a production-ready, secure GitOps management layer using:

✅ **OAuth2/OIDC authentication** (no more shared passwords floating around)  
✅ **External secret management** (credentials never touch Git)  
✅ **Modern Gateway API** (goodbye old-school Ingress)  
✅ **Defense in depth** (RBAC + OAuth2 + rate limiting)

**The result?** Your Flux dashboard is now as secure as your production APIs. No exposed UIs, no credential leaks, just clean OIDC-backed access control.

---

## Next Steps

Want to take this further?

- **Set up monitoring**: Add Grafana dashboards to track auth failures and access patterns
- **Enable audit logging**: Configure Authentik to log all auth events to your SIEM
- **Multi-cluster setup**: Use Flux's multi-tenancy features to manage multiple clusters from one UI
- **Add MFA**: Enable two-factor authentication in Authentik for an extra security layer

---

## Useful Resources

- [Flux Operator Documentation](https://fluxcd.io/flux/operator/)
- [Authentik Provider Configuration](https://docs.goauthentik.io/docs/providers/oauth2/)
- [Kubernetes Gateway API Spec](https://gateway-api.sigs.k8s.io/)
- [External Secrets Operator](https://external-secrets.io/)

---

**Questions or issues?** Drop a comment below or reach out on [Twitter/LinkedIn]. I'm always happy to help troubleshoot!

**Found this helpful?** Consider subscribing to my YouTube channel where I break down Cloud and Kubernetes concepts with real-world implementations like this one.

Happy deploying! 🚀

---

*Last updated: [DATE]*