#!/usr/bin/env bash
# The bundle the platform never signed.
#
# Pushing an OCI artifact needs nothing but registry access. That is the whole
# problem with a registry as a trust boundary, and the reason entitlement lives
# at admission and not in the registry.
#
# This pushes the golden path with one comment added: different bytes, different
# digest, no Chains signature. It goes into the platform's *own* repository on
# purpose, so that example 2 is refused because the digest is not the approved
# one, not because of where it lives.
#
#   make unsigned    push it (part of `make platform`)
#   make trust       show that cosign refuses it
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
mkdir -p "${KEYS}"

# The resource keeps its real file name: push-bundle.py names the layer's tar
# entry after it, so a random temp name would make the digest change on every run
# (the bundle digest must be a function of the bundle's content).
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
{
  echo "# pushed straight into the registry by someone who is not the platform"
  cat "${DEMO_DIR}/platform/pipelines/go-service.yaml"
} > "${WORK}/go-service.yaml"

log "Pushing an unsigned copy of the golden path"
REF="$(python3 "${DEMO_DIR}/scripts/push-bundle.py" \
  "${ZOT_HOST}" platform/pipelines/go-service unapproved "${WORK}/go-service.yaml")"
printf '%s\n' "${REF}" > "${KEYS}/bundle-unsigned.ref"
warn "unsigned: $(printf '%s' "${REF}" | short_ref)"
warn "no signature, and not the approved digest — example 2 references it"
