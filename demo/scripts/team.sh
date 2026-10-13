#!/usr/bin/env bash
# The team's namespace, its identities and its RBAC.
#
#   team-a        the ServiceAccount that enrols the repo and creates runs
#   team-app      the ServiceAccount every build pod runs as: no API permissions
#                 of its own, so a compromised build cannot touch the cluster
#
# The namespace carries the label platform.demo/team=true. That single label is
# what both admission policies match on (platform/policies/), so "is this a team
# namespace" is answered in exactly one place.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Namespace ${TEAM_NS} + ServiceAccounts ${TEAM_NS} (enrolment) and team-app (builds)"
kc create namespace "${TEAM_NS}" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "${TEAM_NS}" label ns "${TEAM_NS}" platform.demo/team=true --overwrite >/dev/null
kc -n "${TEAM_NS}" create serviceaccount "${TEAM_NS}" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "${TEAM_NS}" create serviceaccount team-app --dry-run=client -o yaml | kc apply -f - >/dev/null

log "RBAC: the team SA may create Repository CRs and secrets in its namespace only"
kc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: team-enrolment
  namespace: ${TEAM_NS}
rules:
  - apiGroups: ["pipelinesascode.tekton.dev"]
    resources: ["repositories"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "create", "update", "patch"]
  - apiGroups: ["tekton.dev"]
    resources: ["pipelineruns", "taskruns"]
    verbs: ["get", "list", "watch", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-enrolment
  namespace: ${TEAM_NS}
subjects:
  - kind: ServiceAccount
    name: ${TEAM_NS}
    namespace: ${TEAM_NS}
roleRef:
  kind: Role
  name: team-enrolment
  apiGroup: rbac.authorization.k8s.io
EOF

dashboard_operator "${TEAM_NS}"
log "Team ready: ${TEAM_NS}"
