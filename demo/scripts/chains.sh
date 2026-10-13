#!/usr/bin/env bash
# Tekton Chains: the platform's one signing key pair, and the signing policy.
#
# The private key is generated straight into the secret
# tekton-chains/signing-secrets and is read by the Chains controller only: no
# build step, no developer laptop, no CI credential ever holds it. This single
# pair signs
#
#   * the pipeline bundles the platform publishes  (make publish)
#   * the image and the SLSA provenance of every team build (make example-1)
#
# Nothing else signs during the demo, which is the point: the supply chain is
# signed by the control plane, not by the workload.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
mkdir -p "${KEYS}"

if kc get secret signing-secrets -n tekton-chains -o jsonpath='{.data.cosign\.key}' 2>/dev/null | grep -q .; then
  log "Signing key already in tekton-chains/signing-secrets"
else
  log "Generating the platform signing key (into the Chains secret)"
  # The k8s:// backend has no way to redirect its public half: it writes
  # ./cosign.pub in the current directory. Generate inside keys/ (git-ignored)
  # and drop the copy, because the public key is read back from the cluster.
  ( cd "${KEYS}" && cosign generate-key-pair k8s://tekton-chains/signing-secrets >/dev/null )
  rm -f "${KEYS}/cosign.pub"
fi

# The public half is all the demos need on the workstation: `make trust` and
# `make example-*` verify signatures with it.
kc -n tekton-chains get secret signing-secrets -o jsonpath='{.data.cosign\.pub}' \
  | base64 -d > "${KEYS}/chains.pub"

log "Configuring Chains: SLSA v1.0 provenance + simple signing, OCI storage, no transparency log"
kc -n tekton-chains patch configmap chains-config --type merge -p "$(cat <<EOF
{"data":{
  "artifacts.taskrun.format":"slsa/v2alpha3",
  "artifacts.taskrun.storage":"",
  "artifacts.pipelinerun.format":"slsa/v2alpha3",
  "artifacts.pipelinerun.storage":"oci",
  "artifacts.pipelinerun.enable-deep-inspection":"true",
  "artifacts.oci.format":"simplesigning",
  "artifacts.oci.storage":"oci",
  "artifacts.oci.signer":"x509",
  "transparency.enabled":"false",
  "storage.oci.repository.insecure":"false"
}}
EOF
)" >/dev/null

# Chains must run with our CA to talk to zot over TLS (scripts/tls.sh) and gets
# restarted here so the new configuration is what signs from now on.
kc -n tekton-chains rollout restart deploy/tekton-chains-controller >/dev/null
kc -n tekton-chains rollout status deploy/tekton-chains-controller --timeout=120s >/dev/null

log "Chains ready — public key: keys/chains.pub"
