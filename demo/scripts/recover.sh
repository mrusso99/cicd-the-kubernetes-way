#!/usr/bin/env bash
# Bring a dead cluster back. Two failures that both look like "the demo broke":
#
#  1. The kind node is stopped, or lost its network. Docker Desktop restarting
#     leaves the container exited, and starting it again sometimes fails with
#     "have an old IPv4 address but no current IPv4 address": the fix is to
#     attach it back to the `kind` docker network before starting it.
#
#  2. The Tekton webhook certificate is valid for 7 days. A cluster that has been
#     up longer than that answers every `kubectl apply` of a Tekton object with
#     "x509: certificate has expired or is not yet valid". Restarting the webhook
#     regenerates it — the rotation controller does not fire while the node is
#     down.
#
# Only containers are touched; the node's filesystem (and so zot's artifacts and
# the Chains key) survives.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NODE="${CLUSTER_NAME}-control-plane"

log "Docker: attaching ${NODE} back to the kind network and starting it"
docker network connect kind "${NODE}" 2>/dev/null || true   # fails if already attached
docker update --restart=no "${NODE}" >/dev/null 2>&1 || true
docker start "${NODE}" >/dev/null 2>&1 || true

log "Waiting for the API server"
for _ in $(seq 1 60); do kc get nodes >/dev/null 2>&1 && break; sleep 5; done
kc get nodes >/dev/null 2>&1 || { warn "the API server never came back — make down && make up"; exit 1; }

log "Rotating the Tekton webhook certificate (it is valid for 7 days)"
kc -n tekton-pipelines rollout restart deploy/tekton-pipelines-webhook >/dev/null
kc -n tekton-pipelines rollout status deploy/tekton-pipelines-webhook --timeout=180s >/dev/null

log "Waiting for the platform to settle"
while read -r ns kind name; do
  kc -n "${ns}" get "${kind}/${name}" >/dev/null 2>&1 \
    && kc -n "${ns}" rollout status "${kind}/${name}" --timeout=180s >/dev/null || true
done <<'EOF'
haproxy-ingress daemonset haproxy-kubernetes-ingress
forgejo deployment forgejo
zot deployment zot
tekton-pipelines deployment tekton-pipelines-controller
tekton-chains deployment tekton-chains-controller
pipelines-as-code deployment pipelines-as-code-controller
EOF

ok "recovered — run make status"
