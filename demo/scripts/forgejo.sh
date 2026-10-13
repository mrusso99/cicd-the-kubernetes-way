#!/usr/bin/env bash
# Forgejo bootstrap, and the team's enrolment.
#
# One org, one repo, and TWO distinct technical accounts:
#   pac-svc     -> Pipelines-as-Code writes commit statuses/comments with its token
#   tekton-svc  -> the build itself clones with its own credentials
# Keeping them apart means the audit trail says who did what.
#
# The last step is the self-service one: the Repository CR is applied *as the
# team ServiceAccount*, with no platform credentials involved. Everything before
# it is one-time forge administration, which is why it is a separate target.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

API="http://${FORGEJO_HOST}/api/v1"
ADMIN="${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}"
TEKTON_SVC_PASSWORD="tekton-svc-42"

api() { # api <method> <path> [json]
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "${data}" ]]; then
    curl -sf -u "${ADMIN}" -X "${method}" -H 'Content-Type: application/json' -d "${data}" "${API}${path}"
  else
    curl -sf -u "${ADMIN}" -X "${method}" "${API}${path}"
  fi
}

log "Waiting for Forgejo at ${FORGEJO_HOST}"
for _ in $(seq 1 60); do curl -sf "${API}/version" >/dev/null && break; sleep 2; done
api GET /version >/dev/null || { warn "Forgejo API not reachable"; exit 1; }

api POST /orgs "{\"username\":\"${FORGEJO_ORG}\",\"visibility\":\"public\"}" >/dev/null 2>&1 || true
api POST /orgs "{\"username\":\"${FORGEJO_ORG}\",\"visibility\":\"public\",\"full_name\":\"ACME\"}" >/dev/null 2>&1 || true

for u in pac-svc tekton-svc; do
  api POST /admin/users "{\"username\":\"${u}\",\"password\":\"${TEKTON_SVC_PASSWORD}\",\"email\":\"${u}@demo.test\",\"must_change_password\":false}" >/dev/null 2>&1 || true
done

# The developer. The talk's recordings follow this account pushing from the web
# editor, so the commits are attributed to a person and not to the forge admin.
api POST /admin/users "{\"username\":\"${FORGEJO_DEV_USER}\",\"password\":\"${FORGEJO_DEV_PASSWORD}\",\"email\":\"${FORGEJO_DEV_USER}@demo.test\",\"full_name\":\"Team A · developer\",\"must_change_password\":false}" >/dev/null 2>&1 || true

# Forgejo returns a token's cleartext only once, at creation, so automation
# always mints a fresh one (unique name). The k8s secret is then updated.
mint_token() { # mint_token <user> <scopes-json>
  api POST "/users/$1/tokens" "{\"name\":\"$1-$(date +%s)\",\"scopes\":$2}" 2>/dev/null \
    | jq -r '.sha1 // empty'
}

PAC_TOKEN="$(mint_token pac-svc '["write:repository","write:issue","read:organization"]')"
[[ -n "${PAC_TOKEN}" ]] || { warn "could not obtain a token for pac-svc"; exit 1; }
TEKTON_TOKEN="$(mint_token tekton-svc '["read:repository"]')"
[[ -n "${TEKTON_TOKEN}" ]] || { warn "could not obtain a token for tekton-svc"; exit 1; }

api POST "/orgs/${FORGEJO_ORG}/repos" "{\"name\":\"app\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\"}" >/dev/null 2>&1 || true

# Repository permissions. Without these, Pipelines-as-Code cannot publish commit
# statuses and every run fails its reporting step with
# "cannot use the API on the provider platform to create a in_progress status:
#  user should have a permission to write to a repo" — the token's scopes do not
# help if the account has no write access to the repository.
api PUT "/repos/${FORGEJO_ORG}/app/collaborators/pac-svc" '{"permission":"write"}' >/dev/null 2>&1 || true
api PUT "/repos/${FORGEJO_ORG}/app/collaborators/tekton-svc" '{"permission":"read"}' >/dev/null 2>&1 || true
api PUT "/repos/${FORGEJO_ORG}/app/collaborators/${FORGEJO_DEV_USER}" '{"permission":"write"}' >/dev/null 2>&1 || true

# PaC needs both values; the webhook secret must not be empty.
WEBHOOK_SECRET="$(openssl rand -hex 16)"
kc -n "${TEAM_NS}" create secret generic forgejo-webhook-config \
  --from-literal=provider.token="${PAC_TOKEN}" \
  --from-literal=webhook.secret="${WEBHOOK_SECRET}" \
  --dry-run=client -o yaml | kc -n "${TEAM_NS}" apply -f - >/dev/null

# The build's own git identity.
kc -n "${TEAM_NS}" create secret generic team-git-auth \
  --from-literal=.gitconfig="[credential]
	helper = store
[user]
	name = tekton-svc
	email = tekton-svc@demo.test" \
  --from-literal=.git-credentials="http://tekton-svc:${TEKTON_TOKEN}@${FORGEJO_HOST}" \
  --dry-run=client -o yaml | kc -n "${TEAM_NS}" apply -f - >/dev/null

# Repo webhook -> PaC controller (cluster-internal address, hence ALLOWED_HOST_LIST=*).
api POST "/repos/${FORGEJO_ORG}/app/hooks" "{
  \"type\": \"gitea\",
  \"active\": true,
  \"events\": [\"push\", \"pull_request\", \"issue_comment\"],
  \"config\": {
    \"url\": \"http://pipelines-as-code-controller.pipelines-as-code.svc.cluster.local:8080\",
    \"content_type\": \"json\",
    \"secret\": \"${WEBHOOK_SECRET}\"
  }
}" >/dev/null 2>&1 || warn "webhook may already exist"

log "Enrolling ${FORGEJO_ORG}/app as the team ServiceAccount (self-service)"
kc -n "${TEAM_NS}" --as="system:serviceaccount:${TEAM_NS}:${TEAM_NS}" apply -f - <<EOF
apiVersion: pipelinesascode.tekton.dev/v1alpha1
kind: Repository
metadata:
  name: app
  namespace: ${TEAM_NS}
spec:
  url: "http://${FORGEJO_HOST}/${FORGEJO_ORG}/app"
  git_provider:
    type: forgejo
    url: "http://${FORGEJO_HOST}"
    secret:
      name: forgejo-webhook-config
      key: provider.token
    webhook_secret:
      name: forgejo-webhook-config
      key: webhook.secret
EOF

log "Forgejo ready: org=${FORGEJO_ORG}, repo=app, accounts pac-svc (PaC) + tekton-svc (build)"
