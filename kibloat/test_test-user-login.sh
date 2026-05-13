#!/usr/bin/env bash
KC=http://localhost:8080
TOKEN=$(curl -s -X POST "$KC/realms/fhir-demo/protocol/openid-connect/token" \
  -d "client_id=customer-portal" \
  -d "username=max@acme.de" -d "password=test123" \
  -d "grant_type=password" | jq -r .access_token)

echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.resource_access'
# Erwartet: pkg-administrative, pkg-medical-core   (KEIN pkg-core)