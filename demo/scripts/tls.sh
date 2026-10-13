#!/usr/bin/env bash
# TLS for the registry, with our own CA.
#
# Why this is required: the bundles resolver has no "insecure registry" option —
# it always speaks HTTPS (go-containerregistry default). The ingress default
# certificate is issued for `ingress.local`, so the resolver refuses it. Instead
# of weakening the client, we issue a certificate for our own name and tell the
# controller to trust the CA (config-registry-cert).
#
# The ingress keeps serving plain HTTP as well (ssl-redirect off), so the build
# push and the host-side tooling can stay on HTTP for the demo.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEYS="${DEMO_DIR}/keys"
mkdir -p "${KEYS}"

issue() { # issue <name> <common-name> <sans>
  local name="$1" cn="$2" sans="$3"
  [[ -f "${KEYS}/${name}.crt" ]] && return 0
  log "Issuing certificate ${name} (${sans})"
  openssl req -newkey rsa:2048 -nodes -keyout "${KEYS}/${name}.key" \
    -out "${KEYS}/${name}.csr" -subj "/CN=${cn}" 2>/dev/null
  openssl x509 -req -in "${KEYS}/${name}.csr" -CA "${KEYS}/demo-ca.crt" -CAkey "${KEYS}/demo-ca.key" \
    -CAcreateserial -out "${KEYS}/${name}.crt" -days 825 \
    -extfile <(printf 'subjectAltName=%s\n' "${sans}") 2>/dev/null
}

if [[ -f "${KEYS}/demo-ca.crt" ]]; then
  log "demo CA already present"
else
  log "Generating the demo CA"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${KEYS}/demo-ca.key" -out "${KEYS}/demo-ca.crt" -days 825 \
    -subj "/CN=sovereign-demo-ca" 2>/dev/null
fi

issue "zot-tls" "zot.${DEMO_DOMAIN}" "DNS:zot.${DEMO_DOMAIN},DNS:*.${DEMO_DOMAIN}"

kc -n zot create secret tls zot-tls \
  --cert="${KEYS}/zot-tls.crt" --key="${KEYS}/zot-tls.key" \
  --dry-run=client -o yaml | kc -n zot apply -f - >/dev/null

log "Attaching the certificate to the zot ingress (HTTP stays available)"
# HAProxy serves both HTTP and HTTPS: no redirect is configured, so the plain-HTTP
# push and the host-side tooling keep working without an nginx-style opt-out.
helm --kube-context "${KCTX}" upgrade zot zot --repo https://zotregistry.dev/helm-charts \
  -n zot --reuse-values \
  --set ingress.tls[0].secretName=zot-tls \
  --set ingress.tls[0].hosts[0]="${ZOT_HOST}" \
  --wait --timeout 3m >/dev/null

log "Telling the Pipelines controller to trust our CA"
kc -n tekton-pipelines create configmap config-registry-cert \
  --from-literal=cert="$(cat "${KEYS}/demo-ca.crt")" \
  --dry-run=client -o yaml | kc -n tekton-pipelines apply -f - >/dev/null
kc -n tekton-pipelines rollout restart deploy/tekton-pipelines-controller >/dev/null
kc -n tekton-pipelines rollout status deploy/tekton-pipelines-controller --timeout=120s >/dev/null

# Remote resolution and Chains run in their own namespaces and ship without the
# certificate hook the Pipelines controller has, so they are given the same CA.
grant_ca() { # grant_ca <namespace> <deployment>
  local ns="$1" deploy="$2"
  kc -n "${ns}" get "deploy/${deploy}" >/dev/null 2>&1 || return 0
  kc -n "${ns}" create configmap config-registry-cert \
    --from-literal=cert="$(cat "${KEYS}/demo-ca.crt")" \
    --dry-run=client -o yaml | kc -n "${ns}" apply -f - >/dev/null
  kc -n "${ns}" set env "deploy/${deploy}" \
    SSL_CERT_FILE=/etc/config-registry-cert/cert >/dev/null
  if ! kc -n "${ns}" get "deploy/${deploy}" \
       -o jsonpath='{.spec.template.spec.volumes[*].name}' | grep -qw config-registry-cert; then
    kc -n "${ns}" patch "deploy/${deploy}" --type=json -p '[
      {"op": "add", "path": "/spec/template/spec/volumes/-",
       "value": {"name": "config-registry-cert", "configMap": {"name": "config-registry-cert"}}},
      {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-",
       "value": {"name": "config-registry-cert", "mountPath": "/etc/config-registry-cert"}}]' >/dev/null
  fi
  kc -n "${ns}" rollout status "deploy/${deploy}" --timeout=120s >/dev/null
}

log "Telling the remote resolvers to trust our CA"
grant_ca tekton-pipelines-resolvers tekton-pipelines-remote-resolvers

if kc get ns tekton-chains >/dev/null 2>&1; then
  log "Telling Tekton Chains to trust our CA"
  grant_ca tekton-chains tekton-chains-controller
fi

log "Registry TLS ready: https://${ZOT_HOST}/ (CA: keys/demo-ca.crt)"
