#!/usr/bin/env bash
set -e
KC=http://localhost:8080
REALM=fhir-demo

# Admin-Token holen
ADMIN_TOKEN=$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=admin" -d "password=admin" \
  -d "grant_type=password" | jq -r .access_token)

# Service-Account-User der acme-technical Client-ID finden
SA_USER_ID=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KC/admin/realms/$REALM/users?username=service-account-acme-technical" | jq -r '.[0].id')

# Group-ID von /customers/acme finden
GROUP_ID=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KC/admin/realms/$REALM/group-by-path/customers/acme" | jq -r .id)

# Service Account in Group stecken
curl -s -X PUT -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KC/admin/realms/$REALM/users/$SA_USER_ID/groups/$GROUP_ID"

echo "Service Account zu /customers/acme hinzugefuegt."