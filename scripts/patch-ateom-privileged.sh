#!/bin/bash
# Patches the substrate ateom worker Deployment to privileged: true.
# Must be run after every ate-controller restart (the operator reverts the patch).
#
# Root cause: Linux kernel mounts /sys/fs/cgroup read-only in non-privileged
# containers. gVisor's runsc needs rw access for nested cgroup setup.
# The substrate operator hardcodes privileged: false for gVisor workers.
# No Talos/containerd/kubelet config can override this kernel restriction.
#
# See: docs/substrate-bootstrap-requirements.md §6b
set -euo pipefail

echo "1. Scaling down ate-controller..."
kubectl scale deploy ate-controller -n ate-system --replicas=0
sleep 5

echo "2. Patching kagent-default workers to privileged: true..."
kubectl patch deployment kagent-default -n kagent --type=strategic \
  -p='{"spec":{"template":{"spec":{"containers":[{"name":"ateom","securityContext":{"privileged":true}}]}}}}'

echo "3. Waiting for rollout..."
kubectl rollout status deployment kagent-default -n kagent --timeout=120s

echo "4. Scaling ate-controller back up..."
kubectl scale deploy ate-controller -n ate-system --replicas=1
kubectl rollout status deploy ate-controller -n ate-system --timeout=30s

echo "5. Deleting stale ActorTemplate to force rebuild..."
kubectl delete actortemplate hermes-shell -n kagent --ignore-not-found
sleep 5

echo "6. Reconciling AgentHarness..."
flux reconcile ks agent-harnesses -n kagent --timeout 10s 2>/dev/null || true

echo ""
echo "Done. Monitor with:"
echo "  watch kubectl get agentharness hermes-shell -n kagent"
echo ""
echo "NOTE: ate-controller WILL revert the privileged patch on its next"
echo "reconcile cycle. If hermes-shell becomes Ready before that, the"
echo "golden snapshot is persisted and no further Run RPCs are needed."
