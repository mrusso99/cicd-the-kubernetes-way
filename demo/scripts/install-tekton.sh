#!/usr/bin/env bash
# Install the pinned Tekton components: Pipelines, Chains, Dashboard,
# Pipelines-as-Code. No Triggers: Pipelines-as-Code receives the forge webhooks
# itself, so the EventListener/Triggers layer is not needed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELEASES=https://storage.googleapis.com/tekton-releases

log "Tekton Pipelines ${TEKTON_PIPELINE_VERSION}"
kc apply -f "${RELEASES}/pipeline/previous/${TEKTON_PIPELINE_VERSION}/release.yaml"
wait_rollout tekton-pipelines tekton-pipelines-controller
wait_rollout tekton-pipelines tekton-pipelines-webhook

log "Tekton Chains ${TEKTON_CHAINS_VERSION}"
kc apply -f "${RELEASES}/chains/previous/${TEKTON_CHAINS_VERSION}/release.yaml"
wait_rollout tekton-chains tekton-chains-controller

log "Tekton Dashboard ${TEKTON_DASHBOARD_VERSION}"
kc apply -f "${RELEASES}/dashboard/previous/${TEKTON_DASHBOARD_VERSION}/release.yaml"
wait_rollout tekton-pipelines tekton-dashboard

# The upstream release ships `--read-only=true` and a view-only role binding, so
# the dashboard cannot act on anything. For a local demo we want the buttons to
# work: no auth in front (fine on localhost, not for anything shared) and write
# on the demo namespaces only — see the `dashboard-operator` Role in team.sh and
# publish.sh, which stays per-namespace on purpose.
log "Dashboard: writable (read-only=false) — demo only, no auth in front"
kc -n tekton-pipelines patch deploy tekton-dashboard --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"tekton-dashboard","args":["--read-only=false","--port=9097","--pipelines-namespace=tekton-pipelines","--triggers-namespace=tekton-pipelines","--stream-logs=true","--log-format=json","--log-level=info","--default-namespace=","--external-logs=","--logout-url=","--namespaces="]}]}}}}' >/dev/null
wait_rollout tekton-pipelines tekton-dashboard

log "Pipelines-as-Code ${PAC_VERSION}"
kc apply -f "https://github.com/tektoncd/pipelines-as-code/releases/download/${PAC_VERSION}/release.k8s.yaml"
wait_rollout pipelines-as-code pipelines-as-code-controller
wait_rollout pipelines-as-code pipelines-as-code-watcher

# The forge is self-hosted on a private name: PaC only auto-trusts publicly
# resolvable provider hostnames, so ours must be listed explicitly. The dashboard
# URL makes PaC put a link to the run in the commit status, so a click on the
# check in Forgejo lands on the Tekton Dashboard.
log "Trusting ${FORGEJO_HOST} as provider hostname, linking status to ${DASHBOARD_HOST}"
kc -n pipelines-as-code patch configmap pipelines-as-code --type merge \
  -p "{\"data\":{\"trusted-provider-hostnames\":\"${FORGEJO_HOST}\",\"tekton-dashboard-url\":\"http://${DASHBOARD_HOST}\",\"default-max-keep-runs\":\"5\"}}"

# Dashboard on the same domain as everything else.
kc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tekton-dashboard
  namespace: tekton-pipelines
spec:
  ingressClassName: haproxy
  rules:
    - host: ${DASHBOARD_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: tekton-dashboard
                port:
                  number: 9097
EOF
log "Tekton installed."
