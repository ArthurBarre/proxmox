#!/bin/bash
# Generate Supabase secrets and create K8s secret
# Usage: ./generate-secrets.sh | kubectl --kubeconfig ../../kubeconfig.yaml apply -f -

set -euo pipefail

# Generate a random JWT secret (at least 32 chars)
JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n/+=')
# Generate secret key base for Realtime (64 hex chars)
SECRET_KEY_BASE=$(openssl rand -hex 32)
# Postgres password
POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '\n/+=')

echo "=== Supabase Secrets ===" >&2
echo "JWT_SECRET: $JWT_SECRET" >&2
echo "POSTGRES_PASSWORD: $POSTGRES_PASSWORD" >&2
echo "" >&2

# Generate anon and service_role JWT tokens
# These are standard Supabase JWTs
ANON_KEY=$(python3 -c "
import json, base64, hmac, hashlib, time

secret = '${JWT_SECRET}'

header = base64.urlsafe_b64encode(json.dumps({'alg':'HS256','typ':'JWT'}).encode()).rstrip(b'=').decode()

payload_data = {
    'role': 'anon',
    'iss': 'supabase',
    'iat': int(time.time()),
    'exp': int(time.time()) + 10*365*24*3600
}
payload = base64.urlsafe_b64encode(json.dumps(payload_data).encode()).rstrip(b'=').decode()

sig_input = f'{header}.{payload}'.encode()
sig = base64.urlsafe_b64encode(hmac.new(secret.encode(), sig_input, hashlib.sha256).digest()).rstrip(b'=').decode()

print(f'{header}.{payload}.{sig}')
")

SERVICE_ROLE_KEY=$(python3 -c "
import json, base64, hmac, hashlib, time

secret = '${JWT_SECRET}'

header = base64.urlsafe_b64encode(json.dumps({'alg':'HS256','typ':'JWT'}).encode()).rstrip(b'=').decode()

payload_data = {
    'role': 'service_role',
    'iss': 'supabase',
    'iat': int(time.time()),
    'exp': int(time.time()) + 10*365*24*3600
}
payload = base64.urlsafe_b64encode(json.dumps(payload_data).encode()).rstrip(b'=').decode()

sig_input = f'{header}.{payload}'.encode()
sig = base64.urlsafe_b64encode(hmac.new(secret.encode(), sig_input, hashlib.sha256).digest()).rstrip(b'=').decode()

print(f'{header}.{payload}.{sig}')
")

echo "ANON_KEY: $ANON_KEY" >&2
echo "SERVICE_ROLE_KEY: $SERVICE_ROLE_KEY" >&2
echo "" >&2

# DB URIs
AUTH_DB_URI="postgresql://supabase_auth_admin:${POSTGRES_PASSWORD}@supabase-db.supabase.svc.cluster.local:5432/postgres"
POSTGREST_DB_URI="postgresql://authenticator:${POSTGRES_PASSWORD}@supabase-db.supabase.svc.cluster.local:5432/postgres"
STORAGE_DB_URI="postgresql://supabase_storage_admin:${POSTGRES_PASSWORD}@supabase-db.supabase.svc.cluster.local:5432/postgres"

cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: supabase-secrets
  namespace: supabase
type: Opaque
stringData:
  jwt-secret: "${JWT_SECRET}"
  anon-key: "${ANON_KEY}"
  service-role-key: "${SERVICE_ROLE_KEY}"
  postgres-password: "${POSTGRES_PASSWORD}"
  secret-key-base: "${SECRET_KEY_BASE}"
  auth-db-uri: "${AUTH_DB_URI}"
  postgrest-db-uri: "${POSTGREST_DB_URI}"
  storage-db-uri: "${STORAGE_DB_URI}"
EOF
