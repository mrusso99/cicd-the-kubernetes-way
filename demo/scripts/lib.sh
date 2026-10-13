#!/usr/bin/env bash
# Shared helpers — source me. Expects to run from the demo/ directory.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${DEMO_DIR}/versions.env"

KCTX="kind-${CLUSTER_NAME}"
kc() { kubectl --context "${KCTX}" "$@"; }

# Derived from DEMO_DOMAIN (versions.env stays free of expansions so that both
# make and bash can read it).
FORGEJO_HOST="forgejo.${DEMO_DOMAIN}"
ZOT_HOST="zot.${DEMO_DOMAIN}"
DASHBOARD_HOST="dashboard.${DEMO_DOMAIN}"

TEAM_NS="${TEAM_NS:-team-a}"
PLATFORM_NS="${PLATFORM_NS:-platform}"

KEYS="${DEMO_DIR}/keys"

log()  { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }

node_ip() {
  kc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}

# The names that must resolve from both sides. Single list, two consumers:
# CoreDNS (pods) and the ingress objects. The host side needs no configuration:
# sslip.io encodes 127.0.0.1 in the name and kind publishes 80/443 there.
demo_names() {
  printf '%s\n' "${FORGEJO_HOST}" "${ZOT_HOST}" "${DASHBOARD_HOST}"
}

wait_rollout() { # wait_rollout <namespace> <deployment> [timeout]
  kc -n "$1" rollout status "deploy/$2" --timeout="${3:-300s}"
}

# cosign against our plain-HTTP registry and our own key, with no transparency
# log (the demo is deliberately self-contained: see the README).
cosign_verify() { # cosign_verify <ref>
  cosign verify --key "${KEYS}/chains.pub" --allow-http-registry \
    --insecure-ignore-tlog=true "$1"
}

cosign_verify_attestation() { # cosign_verify_attestation <ref>
  cosign verify-attestation --key "${KEYS}/chains.pub" --type slsaprovenance1 \
    --allow-http-registry --insecure-ignore-tlog=true "$1"
}

# A digest is 71 characters and wraps both a terminal and a slide. Print the
# repository and the first bytes of the digest; the logic always uses the full
# reference, so nothing here is ever compared against.
short_ref() { sed -E 's|(@sha256:[0-9a-f]{12})[0-9a-f]+|\1…|'; }

# The Dashboard is writable in this demo (see install-tekton.sh), so it needs a
# role in every namespace it should act on. Per namespace, on purpose: the demo
# never grants cluster-wide write. Called by team.sh and publish.sh.
dashboard_operator() { # dashboard_operator <namespace>
  kc apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dashboard-operator
  namespace: $1
rules:
  - apiGroups: ["tekton.dev"]
    resources: ["pipelineruns", "taskruns", "pipelines", "tasks", "customruns", "resolutionrequests"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dashboard-operator
  namespace: $1
subjects:
  - kind: ServiceAccount
    name: tekton-dashboard
    namespace: tekton-pipelines
roleRef:
  kind: Role
  name: dashboard-operator
  apiGroup: rbac.authorization.k8s.io
EOF
}
