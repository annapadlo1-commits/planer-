#!/usr/bin/env bash
set -euo pipefail

# Provision the one Storage companion that Supabase requires callers to manage
# through the Storage API. This helper is intentionally local-only.
: "${SUPABASE_STORAGE_URL:?SUPABASE_STORAGE_URL is required}"
: "${SUPABASE_SERVICE_ROLE_KEY:?SUPABASE_SERVICE_ROLE_KEY is required}"

if [[ "${SUPABASE_STORAGE_URL}" =~ ^http://(127[.]0[.]0[.]1|localhost):([1-9][0-9]{0,4})(/storage/v1)?/?$ ]]; then
  storage_port="${BASH_REMATCH[2]}"
else
  echo "refusing non-local Supabase URL" >&2
  exit 1
fi
if ((10#${storage_port} > 65535)); then
  echo "refusing invalid local Storage port" >&2
  exit 1
fi

response_file="$(mktemp)"
cleanup() {
  rm -f "${response_file}"
}
trap cleanup EXIT

status="$({
  curl \
    --silent \
    --show-error \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    --request POST \
    --header "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    --header "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    --header 'Content-Type: application/json' \
    --data-binary '{"id":"profile-avatars","name":"profile-avatars","public":false,"file_size_limit":5242880,"allowed_mime_types":["image/jpeg","image/png","image/webp"],"type":"STANDARD"}' \
    "${SUPABASE_STORAGE_URL%/}/bucket"
} 2>&1)" || {
  echo "Storage API request failed" >&2
  exit 1
}

case "${status}" in
  200|201)
    echo "profile-avatars bucket provisioned through local Storage API"
    ;;
  *)
    echo "Storage API returned HTTP ${status}" >&2
    sed -n '1,20p' "${response_file}" >&2
    exit 1
    ;;
esac
