#!/usr/bin/env bash
# Verify, from outside the cluster, that what runs is what the platform signed.
#
#   the approved bundle     -> the Chains signature verifies
#   the unsigned copy       -> it does not (make unsigned)
#   the last built image    -> signature + SLSA provenance verify
#
# This is the check a release gate — or a human — runs before trusting a digest,
# and the half of the story that admission cannot tell: admission pins a digest,
# cosign proves where that digest came from.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

status=0
check_ok() { # check_ok <label> <ref>
  if cosign_verify "$2" >/dev/null 2>&1; then
    ok "$1: signature verifies ($(printf '%s' "$2" | short_ref))"
  else
    warn "$1: SIGNATURE MISSING or invalid ($(printf '%s' "$2" | short_ref))"; status=1
  fi
}
check_rejected() { # check_rejected <label> <ref>
  if cosign_verify "$2" >/dev/null 2>&1; then
    warn "$1: it verified — that should not happen ($(printf '%s' "$2" | short_ref))"; status=1
  else ok "$1: refused by cosign ($(printf '%s' "$2" | short_ref))"; fi
}

[[ -f "${KEYS}/bundle.ref" ]] || { warn "no approved bundle: run make platform"; exit 1; }
check_ok "approved bundle" "$(cat "${KEYS}/bundle.ref")"

[[ -f "${KEYS}/bundle-unsigned.ref" ]] \
  && check_rejected "unsigned bundle" "$(cat "${KEYS}/bundle-unsigned.ref")"

if [[ -f "${KEYS}/last-image.ref" ]]; then
  REF="$(cat "${KEYS}/last-image.ref")"
  check_ok "last built image" "${REF}"
  if cosign_verify_attestation "${REF}" >/dev/null 2>&1; then
    ok "last built image: SLSA provenance verifies"
  else
    warn "last built image: no SLSA provenance (${REF})"; status=1
  fi
fi

exit "${status}"
