#!/usr/bin/env bash
# Trusted Resources: the platform signs a Task, the control plane verifies the
# signature before the run starts, and a tampered copy is refused.
#
# Two constraints, both measured on 2026-09-11 and both non-obvious:
#
#  1. **v1beta1 only.** The tkn signing CLI handles v1beta1 objects; upstream
#     closed "support v1 for sign and verify" as not planned (cli#2214). A v1
#     Task or Pipeline cannot be signed with the official tooling.
#
#  2. **The CLI must match the control plane's API libraries.** The signature is
#     sha256(json(object)), so the JSON must be byte-identical on both sides.
#     Newer CLIs are built against newer k8s.io/apimachinery, which stops
#     emitting `creationTimestamp: null` on a zero value. With Tekton Pipelines
#     v1.6.0 the controller still emits it, so tkn 0.43+ signs a different byte
#     string and verification fails with
#     "invalid signature when validating ASN.1 encoded signature".
#     tkn 0.41.0 is the newest release aligned with the controller: it verifies.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEAM_NS="${TEAM_NS:-team-a}"
KEYS="${DEMO_DIR}/keys"
BUNDLE_REPO="platform/tasks/hello"

# 1. the CLI that matches the controller: **provided by the operator**.
#    This script does not download binaries and does not touch quarantine
#    attributes. Point TKN_TRUSTED at an aligned tkn, or have it on PATH.
TKN="${TKN_TRUSTED:-tkn}"
have="$("${TKN}" version 2>/dev/null | sed -n 's/.*Client version: *//p' | head -1)"
if [[ "${have}" != "${TKN_TRUSTED_VERSION}" ]]; then
  warn "need tkn ${TKN_TRUSTED_VERSION} (found: ${have:-none})"
  warn "install it yourself and export TKN_TRUSTED=/path/to/tkn — this script never fetches binaries"
  exit 1
fi

# Why the version matters, in one line: the signature is sha256(json(object)), so
# the CLI and the controller must marshal the same bytes. ObjectMeta
# .CreationTimestamp gained `omitzero` (kubernetes/kubernetes#130989, "Omit null
# creationTimestamp", merged 2025-05-02): from that release on, a zero
# creationTimestamp is not written any more. The controller is built from the
# Tekton release pinned in versions.env, so a newer CLI signs different bytes and
# every signature fails with "invalid signature when validating ASN.1 encoded
# signature".
if command -v go >/dev/null 2>&1; then
  api="$(go version -m "$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${TKN}")" 2>/dev/null \
    | awk '$1=="dep" && $2=="k8s.io/apimachinery" {print $3}')"
  case "${api}" in
    v0.3[34].*|v0.3[5-9].*|v0.[4-9]*)
      warn "tkn ${have} is built against k8s.io/apimachinery ${api}: too new for Tekton Pipelines ${TEKTON_PIPELINE_VERSION}"
      warn "a zero creationTimestamp is no longer emitted there, so signatures cannot verify"
      warn "use a CLI built against apimachinery v0.32/v0.33 (tkn ${TKN_TRUSTED_VERSION}), or upgrade the platform"
      exit 1
      ;;
    *)
      log "CLI libraries look compatible (apimachinery ${api:-unknown})"
      ;;
  esac
fi

# 2. the platform's resource-signing key pair: private part stays here, public
#    part goes into the namespace where the runs happen.
if [[ ! -f "${KEYS}/resource.key" ]]; then
  log "Generating the resource-signing key pair (PEM ECDSA P-256)"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${KEYS}/resource.key" 2>/dev/null
  openssl pkey -in "${KEYS}/resource.key" -pubout -out "${KEYS}/resource.pub" 2>/dev/null
fi
kc -n "${TEAM_NS}" create secret generic platform-resource-key \
  --from-file=cosign.pub="${KEYS}/resource.pub" \
  --dry-run=client -o yaml | kc -n "${TEAM_NS}" apply -f - >/dev/null

# 3. sign the task and publish it as a bundle
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
log "Signing ${BUNDLE_REPO} with tkn ${TKN_TRUSTED_VERSION}"
"${TKN}" task sign "${DEMO_DIR}/platform/tasks/hello.yaml" \
  -K="${KEYS}/resource.key" -f="${WORK}/hello-signed.yaml" >/dev/null
grep -q 'tekton.dev/signature' "${WORK}/hello-signed.yaml" || { warn "no signature"; exit 1; }

# a copy whose content changed after signing, signature kept: that is what a
# tampered bundle looks like
sed 's/hello from a task the platform signed/TAMPERED after signing/' \
  "${WORK}/hello-signed.yaml" > "${WORK}/hello-tampered.yaml"

log "Publishing both copies to zot"
python3 "${DEMO_DIR}/scripts/push-bundle.py" "${ZOT_HOST}" "${BUNDLE_REPO}" 1.0.0 \
  "${WORK}/hello-signed.yaml" >/dev/null
python3 "${DEMO_DIR}/scripts/push-bundle.py" "${ZOT_HOST}" "${BUNDLE_REPO}" tampered \
  "${WORK}/hello-tampered.yaml" >/dev/null

# 4. the policy, in the namespace where the runs happen (policies are looked up
#    in the run's namespace), scoped to the tasks bundle on purpose: the v1
#    golden-path pipeline cannot be signed, and with a scoped pattern it is
#    skipped instead of blocking every run.
log "Applying the VerificationPolicy in ${TEAM_NS} (pattern: ${ZOT_HOST}/platform/tasks/)"
kc apply -f - >/dev/null <<EOF
apiVersion: tekton.dev/v1alpha1
kind: VerificationPolicy
metadata:
  name: platform-tasks
  namespace: ${TEAM_NS}
spec:
  resources:
    - pattern: ".*${ZOT_HOST}/platform/tasks/.*"
  authorities:
    - name: platform-resource-key
      key:
        secretRef:
          name: platform-resource-key
          namespace: ${TEAM_NS}
        hashAlgorithm: sha256
  mode: enforce
EOF

log "Enabling Trusted Resources (no-match-policy: ignore, unmatched resources are skipped)"
kc -n tekton-pipelines patch configmap feature-flags --type merge \
  -p '{"data":{"trusted-resources-verification-no-match-policy":"ignore"}}' >/dev/null

# 5. two runs against the same bundle: the signed task and the tampered copy
run() { # run <name> <tag>
  kc -n "${TEAM_NS}" delete taskrun "$1" --ignore-not-found >/dev/null 2>&1 || true
  kc -n "${TEAM_NS}" create -f - >/dev/null <<EOF
apiVersion: tekton.dev/v1beta1
kind: TaskRun
metadata:
  name: $1
  namespace: ${TEAM_NS}
spec:
  taskRef:
    resolver: bundles
    params:
      - name: bundle
        value: ${ZOT_HOST}/${BUNDLE_REPO}:$2
      - name: name
        value: hello
      - name: kind
        value: task
EOF
}

run trusted-good 1.0.0
run trusted-tampered tampered
sleep 20

log "Esito"
kc -n "${TEAM_NS}" get taskrun trusted-good trusted-tampered \
  -o custom-columns=NAME:.metadata.name,SUCCEEDED:.status.conditions[0].status,REASON:.status.conditions[0].reason,VERIFIED:.status.conditions[1].status 2>/dev/null \
  || kc -n "${TEAM_NS}" get taskrun
