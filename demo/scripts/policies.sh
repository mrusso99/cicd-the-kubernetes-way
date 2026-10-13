#!/usr/bin/env bash
# Admission control. Two policies, one label (platform.demo/team=true):
#
#   vap-entitlement   which bundle a PipelineRun may reference. Rendered here
#                     with the digest `make publish` approved.
#   vap-nonroot       no team pod may run as root. Static.
#
#   policies.sh deny   entitlement violations are rejected at admission (default)
#   policies.sh warn   they only warn: the object is created and the client is
#                      told, which is how a platform rolls a rule out
#
# The signature itself is not checked here — a ValidatingAdmissionPolicy cannot
# call cosign. The platform approves a digest that it has *verified* (publish.sh)
# and admission pins it; see the README for the trade-off.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="${1:-deny}"
[[ -f "${KEYS}/bundle.ref" ]] || { warn "no approved bundle yet: run make publish"; exit 1; }
APPROVED="$(cat "${KEYS}/bundle.ref")"

# Trusted Resources (the optional `make trusted`) signs a Task and turns on a
# feature flag. Undo both, so the demo does not depend on which target ran last.
kc -n tekton-pipelines patch configmap feature-flags --type merge \
  -p '{"data":{"trusted-resources-verification-no-match-policy":"ignore"}}' >/dev/null 2>&1 || true
kc -n "${TEAM_NS}" delete verificationpolicy --all --ignore-not-found >/dev/null 2>&1 || true

log "Policy: no team pod may run as root"
kc apply -f "${DEMO_DIR}/platform/policies/vap-nonroot.yaml" >/dev/null

render() {
  # APPROVED_BUNDLE_SHORT first: the full placeholder is a prefix of it, so the
  # other order would rewrite the message placeholder too.
  sed -e "s|APPROVED_BUNDLE_SHORT|$(printf '%s' "${APPROVED}" | short_ref)|g" \
      -e "s|APPROVED_BUNDLE|${APPROVED}|g" \
      -e "s|ZOT_HOST|${ZOT_HOST}|g" \
    "${DEMO_DIR}/platform/policies/vap-entitlement.yaml"
}

case "${MODE}" in
  warn)
    log "Policy: entitlement violations warn (approved $(printf '%s' "${APPROVED}" | short_ref))"
    render | kc apply -f - >/dev/null
    kc delete validatingadmissionpolicybinding tekton-bundle-entitlement-deny \
      --ignore-not-found >/dev/null 2>&1 || true
    ;;
  deny)
    log "Policy: entitlement violations are denied (approved $(printf '%s' "${APPROVED}" | short_ref))"
    render | kc apply -f - >/dev/null
    ;;
  *)
    warn "usage: policies.sh [warn|deny]"
    exit 1
    ;;
esac
