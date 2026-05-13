#!/usr/bin/env bash
set -euo pipefail

KC=http://localhost:8080
REALM=fhir-demo

echo "Warte auf Keycloak..."
until curl -sf "$KC/health/ready" > /dev/null 2>&1; do sleep 2; done
echo "Keycloak bereit."

# --- Admin-Token ---
admin_token() {
  curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" -d "username=admin" -d "password=admin" \
    -d "grant_type=password" | jq -r .access_token
}
TOKEN=$(admin_token)
AUTH="Authorization: Bearer $TOKEN"
CT="Content-Type: application/json"

# --- Helper ---
api() { curl -s -H "$AUTH" -H "$CT" "$@"; }
get() { curl -s -H "$AUTH" "$@"; }

# ============================================================
# 1) Client-Rollen (Verkaufspakete) am fhir-server anlegen
# ============================================================
FHIR_CID=$(get "$KC/admin/realms/$REALM/clients?clientId=fhir-server" | jq -r '.[0].id')

for ROLE in pkg-core pkg-administrative pkg-medical-core; do
  api -X POST "$KC/admin/realms/$REALM/clients/$FHIR_CID/roles" \
    -d "{\"name\":\"$ROLE\"}"
done
echo "Client-Rollen angelegt."

# Rollen-IDs holen
role_id() {
  get "$KC/admin/realms/$REALM/clients/$FHIR_CID/roles/$1" | jq -r .id
}
ROLE_CORE_ID=$(role_id pkg-core)
ROLE_ADM_ID=$(role_id pkg-administrative)
ROLE_MED_ID=$(role_id pkg-medical-core)

# ============================================================
# 2) Group /customers/acme -> gekaufte Pakete zuweisen
# ============================================================
GROUP_ID=$(get "$KC/admin/realms/$REALM/group-by-path/customers/acme" | jq -r .id)

api -X POST "$KC/admin/realms/$REALM/groups/$GROUP_ID/role-mappings/clients/$FHIR_CID" \
  -d "[
    {\"id\":\"$ROLE_ADM_ID\",\"name\":\"pkg-administrative\"},
    {\"id\":\"$ROLE_MED_ID\",\"name\":\"pkg-medical-core\"}
  ]"
echo "Paketrollen an /customers/acme zugewiesen."

# ============================================================
# 3) Service-Account von acme-technical in Group stecken
# ============================================================
SA_USER_ID=$(get "$KC/admin/realms/$REALM/users?username=service-account-acme-technical" | jq -r '.[0].id')
api -X PUT "$KC/admin/realms/$REALM/users/$SA_USER_ID/groups/$GROUP_ID" -d '{}'
echo "Service-Account zu /customers/acme hinzugefuegt."

# ============================================================
# 4) Client Scope "all-packages" mit Hardcoded-Role-Mappern
# ============================================================
api -X POST "$KC/admin/realms/$REALM/client-scopes" \
  -d '{
    "name":"all-packages",
    "protocol":"openid-connect",
    "attributes":{"include.in.token.scope":"true"}
  }'

SCOPE_ID=$(get "$KC/admin/realms/$REALM/client-scopes" | jq -r '.[] | select(.name=="all-packages") | .id')

for ROLE in pkg-core pkg-administrative pkg-medical-core; do
  api -X POST "$KC/admin/realms/$REALM/client-scopes/$SCOPE_ID/protocol-mappers/models" \
    -d "{
      \"name\":\"${ROLE}-mapper\",
      \"protocol\":\"openid-connect\",
      \"protocolMapper\":\"oidc-hardcoded-role-mapper\",
      \"config\":{\"role\":\"fhir-server.${ROLE}\"}
    }"
done
echo "Client Scope 'all-packages' mit Mappern angelegt."

# An internal-superapp als Default-Scope haengen
SUPERAPP_CID=$(get "$KC/admin/realms/$REALM/clients?clientId=internal-superapp" | jq -r '.[0].id')
api -X PUT "$KC/admin/realms/$REALM/clients/$SUPERAPP_CID/default-client-scopes/$SCOPE_ID" -d '{}'
echo "all-packages an internal-superapp gebunden."

# ============================================================
# 5) Authorization Services am fhir-server aktivieren
# ============================================================
FHIR_JSON=$(get "$KC/admin/realms/$REALM/clients/$FHIR_CID")
UPDATED=$(echo "$FHIR_JSON" | jq '.authorizationServicesEnabled = true | .serviceAccountsEnabled = true')
api -X PUT "$KC/admin/realms/$REALM/clients/$FHIR_CID" -d "$UPDATED"
echo "Authorization Services aktiviert."

# Token refreshen (authz aendert manchmal Permissions)
TOKEN=$(admin_token)
AUTH="Authorization: Bearer $TOKEN"

# Scopes
for S in fhir:read fhir:write fhir:search; do
  api -X POST "$KC/admin/realms/$REALM/clients/$FHIR_CID/authz/resource-server/scope" \
    -d "{\"name\":\"$S\"}"
done
echo "Authz-Scopes angelegt."

# Resources
create_resource() {
  api -X POST "$KC/admin/realms/$REALM/clients/$FHIR_CID/authz/resource-server/resource" \
    -d "{
      \"name\":\"$1\",
      \"displayName\":\"$2\",
      \"uris\":$3,
      \"scopes\":[{\"name\":\"fhir:read\"},{\"name\":\"fhir:write\"},{\"name\":\"fhir:search\"}]
    }"
}
create_resource "core-resources" "Core FHIR Resources" '["/fhir/Flag/*"]'
create_resource "administrative-resources" "Administrative FHIR Resources" \
  '["/fhir/Patient/*","/fhir/Encounter/*","/fhir/Practitioner/*","/fhir/CareTeam/*","/fhir/Coverage/*"]'
create_resource "medical-core-resources" "Medical Core FHIR Resources" \
  '["/fhir/Medication/*","/fhir/MedicationStatement/*","/fhir/AllergyIntolerance/*","/fhir/Condition/*"]'
echo "Authz-Resources angelegt."

# Role Policies
create_policy() {
  api -X POST "$KC/admin/realms/$REALM/clients/$FHIR_CID/authz/resource-server/policy/role" \
    -d "{
      \"name\":\"$1\",
      \"logic\":\"POSITIVE\",
      \"decisionStrategy\":\"UNANIMOUS\",
      \"roles\":[{\"id\":\"$FHIR_CID/$2\",\"required\":true}]
    }"
}
create_policy "has-pkg-core" "pkg-core"
create_policy "has-pkg-administrative" "pkg-administrative"
create_policy "has-pkg-medical-core" "pkg-medical-core"
echo "Authz-Policies angelegt."

# Resource Permissions
create_permission() {
  local PERM_NAME=$1 RES_NAME=$2 POL_NAME=$3
  RES_ID=$(get "$KC/admin/realms/$REALM/clients/$FHIR_CID/authz/resource-server/resource?name=$RES_NAME" \
    | jq -r '.[0]._id')
  POL_ID=$(get "$KC/admin/realms/$REALM/clients/$FHIR_CID/authz/resource-server/policy?name=$POL_NAME" \
    | jq -r '.[0].id')
  api -X POST "$KC/admin/realms/$REALM/clients/$FHIR_CID/authz/resource-server/permission/resource" \
    -d "{
      \"name\":\"$PERM_NAME\",
      \"logic\":\"POSITIVE\",
      \"decisionStrategy\":\"AFFIRMATIVE\",
      \"resources\":[\"$RES_ID\"],
      \"policies\":[\"$POL_ID\"]
    }"
}
create_permission "core-permission" "core-resources" "has-pkg-core"
create_permission "administrative-permission" "administrative-resources" "has-pkg-administrative"
create_permission "medical-core-permission" "medical-core-resources" "has-pkg-medical-core"
echo "Authz-Permissions angelegt."

echo ""
echo "============================================"
echo "  Setup komplett!"
echo "  Admin UI: $KC  (admin/admin)"
echo "  Realm:    fhir-demo"
echo "============================================"