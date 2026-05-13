#!/usr/bin/env bash
KC=http://localhost:8080
TOKEN=$(curl -s -X POST "$KC/realms/fhir-demo/protocol/openid-connect/token" \
  -d "client_id=acme-technical" -d "client_secret=acme-secret" \
  -d "grant_type=client_credentials" | jq -r .access_token)

echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.resource_access'
# Erwartet: pkg-administrative, pkg-medical-core (geerbt via Group)