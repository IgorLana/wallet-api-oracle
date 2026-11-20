#!/usr/bin/env bash
# C11 read-only Swagger smoke test. Start the API in another terminal first.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v curl >/dev/null || { echo 'Missing curl' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'Missing python3' >&2; exit 1; }
BASE_URL="${API_URL:-http://localhost:8080}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

printf 'Checking OpenAPI JSON at %s/v3/api-docs ...\n' "$BASE_URL"
curl -fsS --connect-timeout 5 --max-time 30 \
  "$BASE_URL/v3/api-docs" > "$workdir/api.json"

python3 - "$workdir/api.json" <<'PY'
import json
import sys
from pathlib import Path

api = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
assert api.get('openapi', '').startswith('3.'), 'Not an OpenAPI 3 document'
paths = api.get('paths', {})
required = {
    ('/wallets', 'post'),
    ('/wallets/{id}', 'get'),
    ('/wallets/{id}/transactions', 'post'),
    ('/wallets/{id}/transactions', 'get'),
}
for path, method in required:
    operation = paths.get(path, {}).get(method)
    assert operation, f'Missing {method.upper()} {path}'
    security = operation.get('security') or api.get('security', [])
    assert any('apiKeyAuth' in rule for rule in security), f'Missing API key security on {method.upper()} {path}'
    print(f'PASS: {method.upper()} {path}: documented and secured')

scheme = api.get('components', {}).get('securitySchemes', {}).get('apiKeyAuth')
assert scheme and scheme.get('type') == 'apiKey', 'Missing apiKeyAuth security scheme'
assert scheme.get('name') == 'X-API-Key' and scheme.get('in') == 'header', 'Incorrect API key header'
print('PASS: security scheme uses header X-API-Key')

transaction = paths['/wallets/{id}/transactions']['post']
params = transaction.get('parameters', [])
assert any(p.get('name') == 'Idempotency-Key' and p.get('in') == 'header' and p.get('required') for p in params), \
    'Idempotency-Key missing in POST /wallets/{id}/transactions'
print('PASS: Idempotency-Key documented as required header')
assert '422' in transaction.get('responses', {}), 'Missing 422 response for insufficient funds'
assert '409' in transaction.get('responses', {}), 'Missing 409 response for key conflict'
print('PASS: 409 and 422 business responses documented')
PY

printf 'Checking Swagger UI ...\n'
curl -fsSL --connect-timeout 5 --max-time 30 \
  "$BASE_URL/swagger-ui.html" > "$workdir/swagger.html"
test -s "$workdir/swagger.html" || { echo 'Swagger UI page is empty' >&2; exit 1; }
echo 'PASS: Swagger UI reachable'

printf 'Checking unauthenticated wallet request ...\n'
status="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 20 "$BASE_URL/wallets/1")"
if [[ "$status" != 401 ]]; then
  printf 'Expected HTTP 401, got %s\n' "$status" >&2
  exit 1
fi
echo 'PASS: wallet endpoint requires X-API-Key (401)'
echo 'C11 Swagger/OpenAPI smoke checks passed.'
