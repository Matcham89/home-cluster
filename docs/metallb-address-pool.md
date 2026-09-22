# MetalLB address pool — how to change the LoadBalancer IP range

**Purpose:** how to change the range of IPs MetalLB hands out to `type: LoadBalancer`
Services on this cluster, and the constraints that make a change safe. Nothing else in
this repo documented this.

## Where it lives

| What | Path |
|---|---|
| The pool itself | `flux/apps/base/kube-ops/metal-lb/resources/ipaddresspool.yaml` |
| Aggregated by | `flux/apps/base/kube-ops/metal-lb/resources/kustomization.yaml` |
| Applied by | `flux/apps/dev/kube-ops/metal-lb/resources/ks.yaml` (Flux `Kustomization` `metal-lb-resources`, `dependsOn: metal-lb`) |
| MetalLB itself | `flux/apps/base/kube-ops/metal-lb/helmrelease.yaml` (chart `metallb` 0.16.1) |

That one file holds two resources:

- `IPAddressPool/home-pool` — the assignable addresses, currently
  `192.168.1.201`–`192.168.1.216` written as sixteen individual `/32` entries.
- `L2Advertisement/home-adv` — advertises the pool over L2 (ARP). It sets no
  `spec.ipAddressPools`, which in MetalLB means **all** pools are advertised. If you add a
  second pool it is advertised automatically; if you want a pool that is *not* L2-advertised,
  you have to make the selector explicit on `home-adv` first.

**Namespace gotcha:** both resources declare `namespace: metallb` in the file, but the Flux
Kustomization sets `targetNamespace: kube-ops`, which overrides it — they land in `kube-ops`,
the same namespace the MetalLB HelmRelease is installed into. Don't "fix" the in-file
namespace to match what `kubectl get` reports; it is inert either way.

## Editing the range

Edit `spec.addresses` on `home-pool`. MetalLB accepts three interchangeable forms, so the
per-address `/32` list is a style choice, not a requirement:

```yaml
spec:
  addresses:
    - 192.168.1.201/32          # single address
    - 192.168.1.208/29          # CIDR block
    - 192.168.1.201-192.168.1.216  # inclusive start-end range
```

A range or CIDR is far less error-prone than maintaining a long `/32` list, but note that a
CIDR block includes its network and broadcast addresses unless
`spec.avoidBuggyIPs: true` is set.

## Constraints — read before widening or shrinking

1. **Stay outside the LAN DHCP scope.** MetalLB does not coordinate with the router; it just
   answers ARP for whatever you list. Overlapping the DHCP pool produces intermittent,
   hard-to-diagnose address conflicts as the router leases the same IP to a client. The
   router's DHCP range is *not* recorded in this repo — check the router itself before
   extending the pool, don't assume `.201+` is clear just because the current pool ends at
   `.216`.
2. **Don't collide with statically-addressed hosts** on `192.168.1.0/24`. Addresses used by
   this cluster and its dependencies are documented elsewhere in `docs/` rather than here —
   the Talos nodes, the apiserver endpoint, and the off-cluster services host
   (`192.168.1.100`, see `flux/CLAUDE.md` § External Services) all live in this subnet.
3. **`192.168.1.201` must stay in the pool.** It is pinned to the `ingress-gateway`
   LoadBalancer via the `metallb.universe.tf/loadBalancerIPs` annotation in
   `flux/apps/base/ingress/gateway/gateway.yaml`, and every Cloudflare Zero Trust route
   points at `http://192.168.1.201` (see `flux/CLAUDE.md` § Ingress Architecture). Removing
   it from the pool takes all external ingress down, and the fix is not only in this repo —
   the Cloudflare side would have to be repointed too.
4. **Other addresses are pinned by annotation too.** Currently:

   | IP | Pinned by |
   |---|---|
   | `192.168.1.201` | `flux/apps/base/ingress/gateway/gateway.yaml` (ingress-gateway) |
   | `192.168.1.204` | `flux/apps/base/agentgateway-system/agentdesktop/gateway.yaml` |
   | `192.168.1.205` | `flux/apps/base/agentdesktop/controller/helmrelease.yaml` |

   Grep for `loadBalancerIPs` before shrinking the pool — a Service requesting an address
   the pool no longer contains does not fall back to another IP, it goes
   `Pending`/`AllocationFailed`.
5. **Shrinking is not automatically safe even for un-pinned IPs.** Already-assigned
   addresses that drop out of the pool are not renumbered gracefully; expect to delete and
   recreate (or re-annotate) affected Services.

## Applying a change

Changes land **only** via Flux reconciliation from `main` — never `kubectl apply` an edited
manifest by hand, or the next reconcile reverts it and the repo stops describing reality.

```bash
# Validate before pushing
kubectl kustomize flux/apps/base/kube-ops/metal-lb/resources

# After merging to main: FluxInstance syncs main at 1-minute intervals, but the
# metal-lb-resources Kustomization's own interval is 1h — force it if you don't want to wait
flux reconcile kustomization metal-lb-resources --with-source

# Confirm what the cluster actually has
kubectl get ipaddresspool -n kube-ops -o yaml
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

MetalLB picks up pool changes without a restart; existing Service allocations are left
alone as long as their address is still within the pool.
