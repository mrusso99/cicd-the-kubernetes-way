#!/usr/bin/env bash
# The platform publishes the golden path from inside the cluster, and approves
# only a bundle whose signature it has verified.
#
# Tekton Chains produces the signature *after* the run completes, from the
# control plane: this script never sees the private key and never signs anything.
# What it contributes is the gate — wait for Chains, run `cosign verify` with the
# platform public key, and record the digest only if that verification succeeds.
# `make policies` then pins exactly that digest at admission.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
mkdir -p "${KEYS}"
rm -f "${KEYS}/bundle.ref"

kc get ns "${PLATFORM_NS}" >/dev/null 2>&1 || kc create ns "${PLATFORM_NS}" >/dev/null

log "Publisher identity and sources"
kc -n "${PLATFORM_NS}" create serviceaccount platform-publisher \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
dashboard_operator "${PLATFORM_NS}"
kc -n "${PLATFORM_NS}" create configmap publish-sources \
  --from-file=push-bundle.py="${DEMO_DIR}/scripts/push-bundle.py" \
  --from-file=go-service.yaml="${DEMO_DIR}/platform/pipelines/go-service.yaml" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f "${DEMO_DIR}/platform/publish/task.yaml" >/dev/null
kc -n "${PLATFORM_NS}" delete pipelinerun \
  -l platform.demo/publisher=true --ignore-not-found >/dev/null 2>&1 || true

log "Publishing platform/pipelines/go-service:1.0.0 (in-cluster)"
PR="$(sed "s|ZOT_HOST|${ZOT_HOST}|" "${DEMO_DIR}/platform/publish/pipelinerun.yaml" \
  | kc -n "${PLATFORM_NS}" create -f - -o jsonpath='{.metadata.name}')"
kc -n "${PLATFORM_NS}" wait --for=condition=Succeeded "pipelinerun/${PR}" --timeout=300s >/dev/null

URL="$(kc -n "${PLATFORM_NS}" get pipelinerun "${PR}" -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}')"
DIGEST="$(kc -n "${PLATFORM_NS}" get pipelinerun "${PR}" -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')"
[[ -n "${URL}" && -n "${DIGEST}" ]] || { warn "no bundle results on ${PR}"; exit 1; }
REF="${URL}@${DIGEST}"
log "Pushed $(printf '%s' "${REF}" | short_ref)"

log "Waiting for Tekton Chains to sign it"
signed=""
for _ in $(seq 1 60); do
  signed="$(kc -n "${PLATFORM_NS}" get pipelinerun "${PR}" \
    -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}' 2>/dev/null || true)"
  [[ "${signed}" == "true" ]] && break
  sleep 2
done
[[ "${signed}" == "true" ]] || { warn "Chains did not sign ${PR}"; exit 1; }

log "Verifying the signature with the platform public key (cosign)"
err="$(mktemp)"
trap 'rm -f "${err}"' EXIT
if cosign_verify "${REF}" >/dev/null 2>"${err}"; then
  ok "signature verified against keys/chains.pub"
else
  warn "the bundle the platform just published does not verify: ${REF}"
  sed 's/^/    /' "${err}"
  exit 1
fi

printf '%s\n' "${REF}" > "${KEYS}/bundle.ref"
ok "approved $(printf '%s' "$(cat "${KEYS}/bundle.ref")" | short_ref)"
