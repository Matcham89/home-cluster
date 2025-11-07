# Istio Security & Configuration Improvements

## Summary
This document describes the security hardening and configuration improvements applied to the Istio service mesh deployment.

## Changes Applied

### 1. TLS/HTTPS Configuration ✅

**File**: `flux/apps/base/istio-system/istio/gateway/gateway-tls-cert.yaml` (NEW)
- Created Certificate resource for wildcard `*.kubegit.com`
- Uses cert-manager with selfsigned ClusterIssuer
- 90-day certificate with 15-day renewal window
- RSA 2048-bit key

**File**: `flux/apps/base/istio-system/istio/gateway/istio-gateway.yaml` (UPDATED)
- Added HTTPS listener on port 443 with TLS termination
- Configured to use `istio-gateway-tls-cert` secret
- Restricted hostname to `*.kubegit.com`
- Updated allowedRoutes to use namespace selector (istio-gateway-access label)
- HTTP listener on port 80 remains for redirect purposes

### 2. HTTP to HTTPS Redirect ✅

**File**: `flux/apps/base/istio-system/istio/httproutes/http-redirect.yaml` (NEW)
- Created HTTPRoute for automatic HTTP → HTTPS redirect (301)
- Applies to all `*.kubegit.com` hostnames
- Routes bound to HTTP listener only

### 3. HTTPRoute Security Updates ✅

**Files Updated**:
- `flux/apps/base/istio-system/istio/httproutes/grafana-httproute.yaml`
- `flux/apps/base/istio-system/istio/httproutes/kagent.yaml`

**Changes**:
- Updated to use HTTPS listener (`sectionName: https`)
- Added explicit namespace references for backendRefs
- Added request/backend timeouts (30s) for reliability
- Removed HTTP listener bindings (now handled by redirect route)

### 4. Mesh Security - mTLS ✅

**File**: `flux/apps/base/istio-system/istio/security/peer-authentication.yaml` (NEW)
- Enabled STRICT mTLS for all services in istio-system namespace
- Enforces encrypted communication between mesh services
- Does not affect ingress traffic (Gateway → backend services without sidecars)

### 5. Authorization Policies ✅

**Files Created**:
- `flux/apps/base/istio-system/istio/security/authz-grafana.yaml`
- `flux/apps/base/istio-system/istio/security/authz-kagent.yaml`

**Configuration**:
- Created placeholder AuthorizationPolicies for Grafana and kagent
- Configured with `allow-all` rules (`- {}`)
- **Note**: These policies are only enforced if Istio sidecars are injected
- Currently no-op since backend services don't have sidecars (by design)
- Ready for future sidecar injection if needed

### 6. Cloudflared Deployment Hardening ✅

**File**: `flux/apps/base/istio-system/istio/tunnels/cloudflare-tunnel.yaml` (UPDATED)

**Security Improvements**:
- Pinned image version: `cloudflare/cloudflared:2024.11.0` (was: `latest`)
- Added pod security context:
  - `runAsNonRoot: true`
  - `runAsUser: 65532`
  - `fsGroup: 65532`
  - `seccompProfile: RuntimeDefault`
- Added container security context:
  - `allowPrivilegeEscalation: false`
  - `readOnlyRootFilesystem: true`
  - Dropped all capabilities

**Operational Improvements**:
- Changed log level from `debug` to `info`
- Added resource limits and requests:
  - Requests: 50m CPU, 64Mi memory
  - Limits: 200m CPU, 128Mi memory
- Improved probe configuration:
  - Liveness probe failureThreshold: 1 → 3
  - Liveness probe initialDelaySeconds: 10 → 30
  - Added readinessProbe with proper timeouts

### 7. ExternalSecret Configuration Fix ✅

**File**: `flux/apps/base/istio-system/istio/secrets/cloudflare.yaml` (UPDATED)
- Added missing `target` section to tunnel-token ExternalSecret
- Specified `creationPolicy: Owner` and `deletionPolicy: Retain`
- Ensures proper secret lifecycle management

### 8. Namespace Configuration ✅

**File**: `infra/kagent/namespace.yaml` (UPDATED)
- Added label: `istio-gateway-access: "true"` for Gateway access control
- **Did NOT add** `istio-injection: enabled`

**Rationale**:
- Backend services accessed via ingress don't need Istio sidecars
- Avoids unnecessary resource overhead and monitoring complications
- Gateway API + ReferenceGrants handle cross-namespace routing
- mTLS only applies to service-to-service mesh traffic

**Action Required**: Label must also be applied to `monitoring` namespace:
```bash
kubectl label namespace monitoring istio-gateway-access=true
```

### 9. Flux Kustomization Updates ✅

**File**: `flux/apps/dev/istio-system/kustomization.yaml` (UPDATED)
- Added `./istio/security/ks.yaml` to deploy security policies

**File**: `flux/apps/dev/istio-system/istio/security/ks.yaml` (NEW)
- Created Flux Kustomization for security resources
- Depends on `istio-operator`
- Targets istio-system namespace

## Architecture Decisions

### Ingress Traffic Pattern
```
Internet → Gateway (HTTPS:443) → TLS Termination → Backend Services (HTTP:80/8080)
         ↑ has sidecar                              ↑ no sidecars needed
```

**Key Points**:
- Gateway pods have Istio sidecars (part of mesh)
- Backend services (Grafana, kagent) don't have sidecars
- Traffic from Gateway to backends is plain HTTP (east-west within cluster)
- STRICT mTLS applies only to service-to-service mesh traffic
- ReferenceGrants allow Gateway to access services in other namespaces

### Why No Sidecars on Backend Services?
1. **Ingress-only traffic**: Services only receive traffic from Gateway
2. **No service-to-service communication**: They don't talk to other mesh services
3. **Monitoring considerations**: Sidecars can interfere with Prometheus scraping
4. **Resource efficiency**: Avoid unnecessary memory/CPU overhead
5. **Simplicity**: Reduces configuration complexity

### Port Conflict Analysis
**Istio Reserved Ports**: 15000-15090
**Services in use**: 80, 443, 3000, 3100, 3500, 6060, 7946, 8080, 9000-9100, 10250, 11211
**Result**: No conflicts detected ✅

## Security Posture

### Before
- ❌ HTTP-only (no encryption in transit)
- ❌ No mTLS (no service-to-service encryption)
- ❌ No authorization policies
- ❌ Overly permissive gateway (all namespaces)
- ❌ Unstable image tags (`:latest`)
- ❌ Debug logging in production
- ❌ No resource limits
- ❌ Weak security contexts

### After
- ✅ HTTPS with TLS termination
- ✅ Automatic HTTP → HTTPS redirect
- ✅ STRICT mTLS for mesh services
- ✅ Authorization policies (ready for sidecar injection)
- ✅ Namespace-based access control
- ✅ Pinned container versions
- ✅ Info-level logging
- ✅ Resource requests and limits
- ✅ Pod Security Standards compliant
- ✅ Non-root user, read-only filesystem, capabilities dropped

## Deployment Notes

### Prerequisites
1. cert-manager must be installed and ready
2. `selfsigned` ClusterIssuer must exist
3. MetalLB must be configured for LoadBalancer services

### Deployment Order
1. Gateway configuration (TLS cert + Gateway resource)
2. Security policies (PeerAuthentication + AuthZ)
3. HTTPRoutes (redirect + service routes)
4. Cloudflared updates
5. Namespace labels

### Verification Commands
```bash
# Check certificate
kubectl get certificate -n istio-system istio-gateway-tls
kubectl get secret -n istio-system istio-gateway-tls-cert

# Check Gateway
kubectl get gateway -n istio-system istio-gateway
kubectl get svc -n istio-system istio-gateway-istio

# Check HTTPRoutes
kubectl get httproute -n istio-system

# Check security policies
kubectl get peerauthentication -n istio-system
kubectl get authorizationpolicy -A

# Check if port 443 is exposed
kubectl get svc istio-gateway-istio -n istio-system -o yaml | grep -A 5 "- port: 443"

# Test HTTPS
curl -k https://grafana.kubegit.com
curl http://grafana.kubegit.com  # Should redirect to HTTPS
```

### Expected Behavior
1. Gateway LoadBalancer service will automatically update to expose port 443
2. HTTP requests will redirect to HTTPS with 301
3. HTTPS requests will terminate at Gateway and route to backends
4. Backend services will continue to work without sidecars
5. Cloudflared pods will restart with new security settings

## Future Improvements

### Optional Enhancements
1. **Rate Limiting**: Add EnvoyFilter for request rate limiting
2. **WAF Rules**: Consider adding Web Application Firewall rules
3. **Network Policies**: Add Kubernetes NetworkPolicies for defense-in-depth
4. **External DNS**: Automate DNS management for Gateway hostnames
5. **Real Certificates**: Replace self-signed certs with Let's Encrypt
6. **Observability**: Add distributed tracing with OpenTelemetry

### Service-Specific Considerations
If you later need to enable service-to-service mTLS for monitoring or kagent:
1. Add `istio-injection: enabled` label to namespace
2. Update AuthorizationPolicies with specific rules
3. Test Prometheus scraping still works
4. Verify service discovery and metrics endpoints

## Rollback Procedure

If issues arise:
```bash
# Rollback Gateway to HTTP-only
kubectl apply -f <backup-of-original-gateway.yaml>

# Disable mTLS
kubectl delete peerauthentication default-strict-mtls -n istio-system

# Remove security policies
kubectl delete authorizationpolicy -n monitoring grafana-ingress-authz
kubectl delete authorizationpolicy -n kagent kagent-ingress-authz

# Rollback cloudflared
kubectl rollout undo deployment cloudflared-deployment -n istio-system
```

## References
- [Istio Gateway API Documentation](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/)
- [Istio Security Best Practices](https://istio.io/latest/docs/ops/best-practices/security/)
- [Gateway API Specification](https://gateway-api.sigs.k8s.io/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
