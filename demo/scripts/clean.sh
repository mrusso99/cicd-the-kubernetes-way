#!/usr/bin/env bash
# Delete the runs the demo accumulated, and the volumes they leave behind.
#
# Two things bite here, both learned the hard way:
#  - Tekton collects nothing by itself: a run from a volumeClaimTemplate leaves
#    its PVC, and completed TaskRuns and Pods stay until deleted.
#  - Chains puts a finalizer on every PipelineRun it signs. Deleting the TaskRuns
#    first leaves the PipelineRun un-processable and it sits in Terminating
#    forever, retrying with "FinalizerUpdateFailed". So: PipelineRuns first, wait
#    for Chains to release them, then everything else.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for ns in "${TEAM_NS}" "${PLATFORM_NS}"; do
  kc get ns "${ns}" >/dev/null 2>&1 || continue
  log "Cleaning ${ns}"

  kc -n "${ns}" delete pipelinerun --all --wait=false --ignore-not-found >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    [[ -z "$(kc -n "${ns}" get pipelinerun -o name 2>/dev/null)" ]] && break
    sleep 3
  done

  # anything Chains is still holding: drop the finalizer explicitly
  for pr in $(kc -n "${ns}" get pipelinerun -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    warn "Chains is still holding ${pr}: dropping its finalizer"
    kc -n "${ns}" patch pipelinerun "${pr}" --type=merge \
      -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done

  kc -n "${ns}" delete taskrun --all --wait=false --ignore-not-found >/dev/null 2>&1 || true
  kc -n "${ns}" delete resolutionrequest --all --wait=false --ignore-not-found >/dev/null 2>&1 || true
  kc -n "${ns}" delete pvc --all --wait=false --ignore-not-found >/dev/null 2>&1 || true
  kc -n "${ns}" delete pod --all --wait=false --ignore-not-found >/dev/null 2>&1 || true

  printf '  %-9s runs=%s taskruns=%s pvc=%s pods=%s\n' "${ns}" \
    "$(kc -n "${ns}" get pipelinerun --no-headers 2>/dev/null | wc -l | tr -d ' ')" \
    "$(kc -n "${ns}" get taskrun --no-headers 2>/dev/null | wc -l | tr -d ' ')" \
    "$(kc -n "${ns}" get pvc --no-headers 2>/dev/null | wc -l | tr -d ' ')" \
    "$(kc -n "${ns}" get pod --no-headers 2>/dev/null | wc -l | tr -d ' ')"
done

log "Retention: PaC keeps the last 5 runs per repo (install-tekton.sh)"
