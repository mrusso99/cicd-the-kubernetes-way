#!/usr/bin/env bash
# Make DEMO_DOMAIN resolve inside the cluster to the node IP, so the ingress is
# reachable from pods with the *same* hostname the host uses.
#
# The host side needs no work: sslip.io encodes the IP in the name
# (<name>.127-0-0-1.sslip.io -> 127.0.0.1) and kind publishes 80/443 there.
# The pod side needs one extra CoreDNS server block (default ``.:53`` untouched).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NODE_IP="$(node_ip)"
names="$(demo_names | tr '\n' ' ' | sed 's/ $//')"

block="$(printf '%s:53 {\n    errors\n    hosts {\n        %s %s\n        fallthrough\n    }\n    cache 30\n}\n' \
  "${DEMO_DOMAIN}" "${NODE_IP}" "${names}")"

current="$(kc -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
if grep -qF "${DEMO_DOMAIN}:53" <<<"${current}"; then
  log "CoreDNS already serves ${DEMO_DOMAIN}"
else
  log "CoreDNS: ${DEMO_DOMAIN} -> ${NODE_IP} (${names})"
  kc -n kube-system get configmap coredns -o json |
    python3 -c '
import json, sys
cm = json.load(sys.stdin)
cm["data"]["Corefile"] = cm["data"]["Corefile"].rstrip() + "\n" + sys.argv[1]
json.dump(cm, sys.stdout)
' "${block}" |
    kc apply -f - >/dev/null
  sleep 5   # the reload plugin polls the ConfigMap
fi

log "host : $(demo_names | tr '\n' ' ')"
log "pods : same names -> ${NODE_IP}"
