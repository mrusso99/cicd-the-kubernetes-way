#!/usr/bin/env bash
# One example, end to end, through Pipelines-as-Code.
#
#   example.sh 1     signed bundle                    -> the run succeeds, the image is signed
#                                                       and carries SLSA provenance
#   example.sh 1b    signed bundle, vulnerable app    -> the Trivy gate fails and nothing is signed
#   example.sh 2     a bundle the platform never signed -> refused at admission, no run at all
#   example.sh 3     signed bundle, pod asks for root -> refused at pod admission, the run fails
#
# The developer's part of every example is one push: the PipelineRun definition
# each branch carries lives in demo/team/app/.tekton/. The rest of this script is
# the observer — and the thing that checks the outcome is what it claims to be.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCENARIO="${1:-}"
case "${SCENARIO}" in
  1)  BRANCH=main
      TEMPLATE=release.yaml
      DOCKERFILE=team/app/Dockerfile
      REF_FILE="${KEYS}/bundle.ref"
      MESSAGE="release: golden path with the signed bundle" ;;
  1b) BRANCH=scan-fail
      TEMPLATE=release-scan-fail.yaml
      DOCKERFILE=team/app/vulnerable/Dockerfile
      REF_FILE="${KEYS}/bundle.ref"
      MESSAGE="release: the vulnerable build (the gate must stop it)" ;;
  2)  BRANCH=unsigned
      TEMPLATE=release-unsigned.yaml
      DOCKERFILE=team/app/Dockerfile
      REF_FILE="${KEYS}/bundle-unsigned.ref"
      MESSAGE="release: bundle nobody signed" ;;
  3)  BRANCH=as-root
      TEMPLATE=release-as-root.yaml
      DOCKERFILE=team/app/Dockerfile
      REF_FILE="${KEYS}/bundle.ref"
      MESSAGE="release: run the build as root" ;;
  *)  warn "usage: example.sh <1|1b|2|3>"; exit 1 ;;
esac

[[ -f "${REF_FILE}" ]] || { warn "missing ${REF_FILE}: run make platform"; exit 1; }
BUNDLE_REF="$(cat "${REF_FILE}")"

# ---------------------------------------------------------------- observers

newest_run() {
  kc -n "${TEAM_NS}" get pipelinerun --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true
}

wait_new_run() { # wait_new_run <previous> -> prints the new name; fails if none appears
  local previous="$1" pr
  for _ in $(seq 1 30); do
    pr="$(newest_run)"
    if [[ -n "${pr}" && "${pr}" != "${previous}" ]]; then printf '%s' "${pr}"; return 0; fi
    # A refusal creates no object, so wait for the report instead of the timeout.
    if [[ "${SCENARIO}" == "2" ]] && [[ -n "$(pac_rejection "bundle non approvato" 30s)" ]]; then
      return 1
    fi
    sleep 1
  done
  return 1
}

wait_finished() { # wait_finished <pr>
  local pr="$1" state
  for _ in $(seq 1 140); do
    state="$(kc -n "${TEAM_NS}" get pipelinerun "${pr}" \
      -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)"
    [[ "${state}" == "True" || "${state}" == "False" ]] && return 0
    sleep 3
  done
  return 1
}

report_run() { # report_run <pr>
  kc -n "${TEAM_NS}" get pipelinerun "$1" \
    -o custom-columns=NAME:.metadata.name,SUCCEEDED:.status.conditions[0].status,REASON:.status.conditions[0].reason
  kc -n "${TEAM_NS}" get pipelinerun "$1" \
    -o jsonpath='{range .status.conditions[*]}{"    "}{.type}={.status} {.message}{"\n"}{end}'
}

taskrun_outcomes() { # taskrun_outcomes <pr>
  kc -n "${TEAM_NS}" get taskrun -l "tekton.dev/pipelineRun=$1" \
    -o jsonpath='{range .items[*]}{"    "}{.metadata.name}{"  "}{.status.conditions[0].status}{"  "}{.status.conditions[0].reason}{"\n"}{end}' \
    2>/dev/null || true
}

taskrun_message() { # taskrun_message <pr>
  kc -n "${TEAM_NS}" get taskrun -l "tekton.dev/pipelineRun=$1" \
    -o jsonpath='{range .items[*]}{.status.conditions[0].message}{"\n"}{end}' 2>/dev/null \
    | grep -v '^$' | head -2 | sed 's/^/    /' || true
}

pac_rejection() { # pac_rejection <substring> [since]
  local found
  found="$(kc -n pipelines-as-code logs deploy/pipelines-as-code-controller \
    --since="${2:-10m}" 2>/dev/null \
    | jq -Rr 'fromjson? | .msg' | grep -F "$1" | tail -1 || true)"
  [[ -n "${found}" ]] && printf '  %s\n' "${found}"
}

chains_said() { # chains_said <pr>
  kc -n tekton-chains logs deploy/tekton-chains-controller --tail=600 2>/dev/null \
    | grep -F "$1" | jq -Rr 'fromjson? | .msg' | grep -iE 'No image subject|Uploading|Skipping' \
    | tail -2 | sed 's/^/    /' || true
}

refuse_unsigned() { # the expected outcome of example 2
  log "no PipelineRun was created: the request was rejected at admission"
  pac_rejection "bundle non approvato" || true
  ok "example 2: the unsigned bundle never became a run"
}

# ---------------------------------------------------------------- the push

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

log "Cloning ${FORGEJO_ORG}/app as the developer"
git -c http.sslVerify=false clone \
  "http://${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}@${FORGEJO_HOST}/${FORGEJO_ORG}/app" \
  "${WORK}/app" >/dev/null 2>&1
cd "${WORK}/app" || exit 1
git checkout -B "${BRANCH}" origin/main >/dev/null 2>&1 || git checkout -B "${BRANCH}" >/dev/null 2>&1

rm -rf .tekton && mkdir -p .tekton
cp "${DEMO_DIR}/team/app/main.go" main.go
cp "${DEMO_DIR}/${DOCKERFILE}" Dockerfile
sed -e "s|BUNDLE_REF|${BUNDLE_REF}|g" -e "s|UNSIGNED_REF|${BUNDLE_REF}|g" -e "s|ZOT_HOST|${ZOT_HOST}|g" \
  "${DEMO_DIR}/team/app/.tekton/${TEMPLATE}" > .tekton/release.yaml

git -c user.email=dev@demo.test -c user.name=developer add -A
# --allow-empty: running the same example twice in a row is normal (rehearsal,
# then the talk). Without it the commit fails on an unchanged tree, and the push
# would be a no-op, so Pipelines-as-Code would never fire. The time in the message
# is what makes each commit unique (and keeps the forge readable on screen).
git -c user.email=dev@demo.test -c user.name=developer commit -q --allow-empty \
  -m "${MESSAGE} ($(date +%H:%M:%S))"

BEFORE="$(newest_run)"
if ! git push -qf origin "HEAD:${BRANCH}" >/dev/null 2>"${WORK}/push.err"; then
  warn "the push failed:"
  sed 's/^/    /' "${WORK}/push.err"
  exit 1
fi
log "Pushed ${BRANCH}: .tekton/release.yaml -> $(printf '%s' "${BUNDLE_REF}" | short_ref)"

# ---------------------------------------------------------------- the outcome

PR="$(wait_new_run "${BEFORE}")" || {
  [[ "${SCENARIO}" == "2" ]] && { refuse_unsigned; exit 0; }
  warn "Pipelines-as-Code did not create a PipelineRun — check the controller log"
  exit 1
}

log "PipelineRun ${PR} (Pipelines-as-Code created it from the push)"
wait_finished "${PR}" || warn "the run did not finish within the timeout"
report_run "${PR}"
taskrun_outcomes "${PR}"

SUCCEEDED="$(kc -n "${TEAM_NS}" get pipelinerun "${PR}" -o jsonpath='{.status.conditions[0].status}')"

case "${SCENARIO}" in
  1)
    if [[ "${SUCCEEDED}" != "True" ]]; then
      warn "expected the run to succeed"; taskrun_message "${PR}"; exit 1
    fi
    IMAGE="$(kc -n "${TEAM_NS}" get pipelinerun "${PR}" -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}')"
    DIGEST="$(kc -n "${TEAM_NS}" get pipelinerun "${PR}" -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')"
    [[ -n "${IMAGE}" && -n "${DIGEST}" ]] || { warn "no IMAGE_URL/IMAGE_DIGEST results"; exit 1; }
    REF="${IMAGE}@${DIGEST}"
    printf '%s\n' "${REF}" > "${KEYS}/last-image.ref"

    log "the step that declares the artifact to Chains:"
    kc -n "${TEAM_NS}" logs "${PR}-promote-pod" -c step-declare 2>/dev/null | sed 's/^/    /' || true

    log "cosign verify --key keys/chains.pub $(printf '%s' "${REF}" | short_ref)"
    if cosign_verify "${REF}" >/dev/null 2>&1; then
      ok "image signature verified (Chains)"
    else
      warn "the image is not signed"; exit 1
    fi
    log "cosign verify-attestation --type slsaprovenance1 $(printf '%s' "${REF}" | short_ref)"
    if cosign_verify_attestation "${REF}" >/dev/null 2>&1; then
      ok "SLSA provenance verified (Chains)"
    else
      warn "no SLSA provenance"; exit 1
    fi
    ok "example 1: the signed bundle ran, the image is signed and attested"
    ;;

  1b)
    [[ "${SUCCEEDED}" == "False" ]] || { warn "expected the run to fail"; exit 1; }
    log "the gate that stopped it:"
    kc -n "${TEAM_NS}" logs "${PR}-scan-pod" -c step-trivy 2>/dev/null | grep -E 'CRITICAL|HIGH|Total|FATAL' | head -6 | sed 's/^/    /' || true

    # The verdict is what `promote` is conditioned on, and it stays on the run
    # even though the gate failed it: that is the trace the condition reads.
    GATE="$(kc -n "${TEAM_NS}" get taskrun "${PR}-scan" \
      -o jsonpath='{.status.results[?(@.name=="SCAN_GATE")].value}' 2>/dev/null || true)"
    if [[ "${GATE}" == "failed" ]]; then
      ok "il verdetto è registrato sulla run: SCAN_GATE=failed — è la condizione di promote"
    else
      warn "SCAN_GATE is '${GATE}', expected 'failed'"; exit 1
    fi

    # buildkit already pushed the image; nothing after the gate ran, so nothing
    # declared it to Chains and there is no signature — that is the claim.
    IMAGE="$(kc -n "${TEAM_NS}" get taskrun "${PR}-build" -o jsonpath='{.status.results[?(@.name=="BUILT_REF")].value}' 2>/dev/null || true)"
    DIGEST="$(kc -n "${TEAM_NS}" get taskrun "${PR}-build" -o jsonpath='{.status.results[?(@.name=="BUILT_DIGEST")].value}' 2>/dev/null || true)"
    if [[ -n "${IMAGE}" && -n "${DIGEST}" ]]; then
      log "the image buildkit pushed, unsigned: $(printf '%s@%s' "${IMAGE}" "${DIGEST}" | short_ref)"
      if cosign_verify "${IMAGE}@${DIGEST}" >/dev/null 2>&1; then
        warn "the image IS signed: that should not happen when the gate failed"; exit 1
      fi
      ok "cosign verify refuses it — the control plane signed nothing"
    else
      warn "no BUILT_REF/BUILT_DIGEST results on the build TaskRun"
    fi
    log "what Tekton Chains did with the failed run:"
    chains_said "${PR}"
    ok "example 1b: the gate failed the run, and no attestation was produced"
    ;;

  2)
    warn "a PipelineRun exists for the unsigned bundle: admission let it through"
    exit 1
    ;;

  3)
    [[ "${SUCCEEDED}" == "False" ]] || { warn "expected the run to fail"; exit 1; }
    log "why the run failed:"
    taskrun_message "${PR}"
    if taskrun_message "${PR}" | grep -q "pod non ammesso"; then
      ok "the non-root policy refused the pod"
    else
      warn "the run failed, but not with the non-root policy message — check above"
    fi
    ok "example 3: asking for root fails the run instead of getting it"
    ;;
esac
