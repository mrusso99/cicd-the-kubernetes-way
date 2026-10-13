# Sovereign CI/CD demo — one cluster, one domain, one signing key.
#
#   make up        everything, from nothing: cluster, forge, registry, Tekton, platform
#   make demo      the four examples, one after the other
#   make down      delete the cluster
#
# Requires: docker, kind, kubectl, helm, cosign, python3, jq, openssl, git
SHELL := /bin/bash
include versions.env
export

KCTX := kind-$(CLUSTER_NAME)
HELM := helm --kube-context $(KCTX)

# Derived from the single DEMO_DOMAIN, exactly as scripts/lib.sh derives them.
FORGEJO_HOST := forgejo.$(DEMO_DOMAIN)
ZOT_HOST := zot.$(DEMO_DOMAIN)
DASHBOARD_HOST := dashboard.$(DEMO_DOMAIN)

.DEFAULT_GOAL := up
.PHONY: help up platform demo record example-1 example-1b example-2 example-3 \
        cluster dns ingress zot tekton tls forgejo chains teams bootstrap \
        publish unsigned policies policies-warn policies-deny \
        trust trusted status verify clean down recover

help: ## this help
	@echo "Sovereign CI/CD demo"
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | sort | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ------------------------------------------------------------------- life cycle

up: cluster dns ingress zot tekton tls forgejo platform ## bring the whole platform up from nothing
	@echo
	@echo "▸ platform ready — see make status, then make demo"

platform: chains teams bootstrap publish unsigned policies ## the platform layer: keys, forge bootstrap, policy, bundles
	@echo "▸ platform configured"

demo: policies-deny example-1 example-1b example-2 example-3 ## run every example in order

record: ## record the examples as GIFs + posters (all, or S=1|1b|2|3)
	@bash scripts/record.sh $(or $(S),all)

# ------------------------------------------------------------------- examples

example-1: ## signed bundle: the run succeeds, the image is signed and attested
	@bash scripts/example.sh 1

example-1b: ## vulnerable app on the same signed bundle: the Trivy gate fails, nothing is signed
	@bash scripts/example.sh 1b

example-2: policies-deny ## a bundle the platform never signed: refused at admission, no run at all
	@bash scripts/example.sh 2

example-3: policies-deny ## the signed bundle started as root: the pod is refused, the run fails
	@bash scripts/example.sh 3

policies: ## apply both admission policies from the approved digest (deny)
	@bash scripts/policies.sh deny

policies-warn: ## entitlement violations only warn (the run is still created)
	@bash scripts/policies.sh warn

policies-deny: ## entitlement violations are rejected at admission
	@bash scripts/policies.sh deny

trust: ## verify with cosign: approved bundle, unsigned copy, last built image
	@bash scripts/trust.sh

trusted: ## (extra) Trusted Resources: a signed Task, and the control plane refusing a tampered copy
	@bash scripts/trusted-resources.sh

# ------------------------------------------------------------------- platform

chains: ## the platform signing key pair, confined to the Chains secret, and the Chains config
	@bash scripts/chains.sh

teams: ## team namespace, ServiceAccounts and RBAC
	@bash scripts/team.sh

bootstrap: teams ## forge org, repo, technical accounts, secrets, webhook, enrolment
	@bash scripts/forgejo.sh

publish: chains ## the platform publishes the golden path; Chains signs it; publish verifies it
	@bash scripts/publish.sh

unsigned: ## the bundle the platform never signed (example 2 references it)
	@bash scripts/unsigned.sh

# ------------------------------------------------------------------- components

cluster: ## create the kind cluster (idempotent; carries the port mappings)
	@kind get clusters 2>/dev/null | grep -qx '$(CLUSTER_NAME)' \
	  && echo "▸ cluster $(CLUSTER_NAME) already exists" \
	  || kind create cluster --config kind/cluster.yaml --image $(KIND_NODE_IMAGE) --wait 180s

dns: cluster ## the same FQDNs inside the cluster, via CoreDNS
	@bash scripts/dns.sh

ingress: ## HAProxy Kubernetes Ingress Controller, bound to the node's 80/443
	@$(HELM) upgrade --install haproxy kubernetes-ingress \
	  --repo https://haproxytech.github.io/helm-charts \
	  -n haproxy-ingress --create-namespace \
	  --version $(HAPROXY_INGRESS_CHART_VERSION) \
	  -f values/haproxy-ingress.yaml --wait --timeout 5m

zot: ## OCI-native registry: images, signed bundles, attestations
	@$(HELM) upgrade --install zot zot \
	  --repo https://zotregistry.dev/helm-charts \
	  -n zot --create-namespace \
	  --version $(ZOT_CHART_VERSION) \
	  -f values/zot.yaml \
	  --set ingress.hosts[0].host=$(ZOT_HOST) \
	  --wait --timeout 5m

tekton: ## Pipelines, Chains, Dashboard, Pipelines-as-Code
	@bash scripts/install-tekton.sh

tls: ## our CA and a certificate for the registry, trusted by the Tekton controllers
	@bash scripts/tls.sh

forgejo: ## the forge the teams push to
	@$(HELM) upgrade --install forgejo oci://code.forgejo.org/forgejo-helm/forgejo \
	  -n forgejo --create-namespace \
	  --version $(FORGEJO_CHART_VERSION) \
	  -f values/forgejo.yaml \
	  --set ingress.hosts[0].host=$(FORGEJO_HOST) \
	  --set gitea.config.server.ROOT_URL=http://$(FORGEJO_HOST)/ \
	  --set gitea.config.server.DOMAIN=$(FORGEJO_HOST) \
	  --wait --timeout 10m

# ------------------------------------------------------------------- operations

status: ## endpoints, the approved bundle, and anything not running
	@echo "Forgejo:   http://$(FORGEJO_HOST)/   (admin: $(FORGEJO_ADMIN_USER) / $(FORGEJO_ADMIN_PASSWORD))"
	@echo "zot:       http://$(ZOT_HOST)/v2/_catalog"
	@echo "Dashboard: http://$(DASHBOARD_HOST)/"
	@echo
	@if [ -f keys/bundle.ref ]; then echo "approved:  $$(cat keys/bundle.ref)"; else echo "approved:  (none — run make platform)"; fi
	@echo
	@kubectl --context $(KCTX) get pods -A --no-headers 2>/dev/null \
	  | awk '$$4!="Running" && $$4!="Completed" {print "  not ready: "$$0}' || true

verify: ## requirement: one hostname, reachable from the host AND from inside a pod
	@echo "== from the host (sslip.io -> 127.0.0.1 -> the ports kind publishes)"
	@for n in $(FORGEJO_HOST) $(ZOT_HOST); do \
	  printf '  %-40s %s\n' "$$n" "$$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://$$n/ || echo unreachable)"; done
	@echo "== from a pod (CoreDNS -> the ingress)"
	@kubectl --context $(KCTX) -n default run dns-probe-$$RANDOM --rm -i --restart=Never \
	  --image=curlimages/curl:8.11.1 --quiet -- \
	  sh -c 'for n in $(FORGEJO_HOST) $(ZOT_HOST); do printf "  %-40s %s\n" "$$n" "$$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 http://$$n/ || echo unreachable)"; done' 2>/dev/null

clean: ## delete the runs and volumes the demo accumulated
	@bash scripts/clean.sh

recover: ## bring back a stopped cluster and rotate the Tekton webhook certificate
	@bash scripts/recover.sh

down: ## delete the cluster (and the refs that pointed into it)
	@kind delete cluster --name $(CLUSTER_NAME) || true
	@rm -f keys/*.ref
	@echo "▸ removed the recorded bundle and image references"
