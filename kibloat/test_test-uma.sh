#!/usr/bin/env bash
KC=http://localhost:8080

USER_TOKEN=$(curl -s -X POST "$KC/realms/fhir-demo/protocol/openid-connect/token" \
  -d "client_id=customer-portal" -d "username=max@acme.de" -d "password=test123" \
  -d "grant_type=password" | jq -r .access_token)

# RPT (Requesting Party Token) vom fhir-server holen
curl -s -X POST "$KC/realms/fhir-demo/protocol/openid-connect/token" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:uma-ticket" \
  -d "audience=fhir-server" \
  -d "response_mode=permissions" | jq
# Erwartet: Liste mit administrative-resources + medical-core-resources