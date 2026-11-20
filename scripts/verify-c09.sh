#!/usr/bin/env bash
# HTTP smoke test. Creates permanent development data (C09 Smoke wallet).
# Run with API already started: bash scripts/verify-c09.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ ! -f .env ]]; then echo 'Missing .env' >&2; exit 1; fi
set -a
# shellcheck disable=SC1091
source ./.env
set +a
: "${WALLET_API_KEY:?Set WALLET_API_KEY in .env}"
command -v curl >/dev/null || { echo 'curl required' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'python3 required' >&2; exit 1; }
BASE_URL="${API_URL:-http://localhost:8080}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
body="$workdir/body.json"
headers="$workdir/headers.txt"

http() {
  local expected="$1"; shift
  local got
  got="$(curl -sS -D "$headers" -o "$body" -w '%{http_code}' "$@")"
  if [[ "$got" != "$expected" ]]; then
    echo "FAIL: expected HTTP $expected, got $got" >&2
    cat "$body" >&2
    exit 1
  fi
}

json_field() {
  python3 - "$body" "$1" <<'PYFIELD'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f: data=json.load(f)
print(data[sys.argv[2]])
PYFIELD
}

assert_field() {
  python3 - "$body" "$1" "$2" <<'PYFIELD'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f: data=json.load(f)
actual = data[sys.argv[2]]
expected = sys.argv[3]
assert str(actual) == expected or (isinstance(actual, (int,float)) and float(expected) == actual), (actual, expected)
PYFIELD
}

# Missing API key must be rejected before controller invocation.
http 401 "$BASE_URL/wallets/1"
assert_field code UNAUTHORIZED
echo 'PASS: missing X-API-Key -> 401'

http 201 -X POST "$BASE_URL/wallets" \
  -H "X-API-Key: $WALLET_API_KEY" -H 'Content-Type: application/json' \
  --data '{"holderName":"C09 Smoke"}'
wallet_id="$(json_field id)"
assert_field balance 0
echo "PASS: create wallet -> $wallet_id"

http 200 -H "X-API-Key: $WALLET_API_KEY" "$BASE_URL/wallets/$wallet_id"
assert_field balance 0
echo 'PASS: read wallet'

prefix="c09-$(date +%s)-$$"
post_transaction() {
  local expected="$1" key="$2" typ="$3" amount="$4"
  http "$expected" -X POST "$BASE_URL/wallets/$wallet_id/transactions" \
    -H "X-API-Key: $WALLET_API_KEY" \
    -H "Idempotency-Key: $key" \
    -H 'Content-Type: application/json' \
    --data "{\"type\":\"$typ\",\"amount\":$amount}"
}

post_transaction 201 "$prefix-credit-1" CREDIT 100.00
assert_field balanceAfter 100
echo 'PASS: credit 100 -> balance 100'
post_transaction 201 "$prefix-debit-1" DEBIT 30.00
assert_field balanceAfter 70
echo 'PASS: debit 30 -> balance 70'
post_transaction 422 "$prefix-debit-rejected" DEBIT 100.00
assert_field code INSUFFICIENT_FUNDS
echo 'PASS: reject insufficient-funds debit'
post_transaction 201 "$prefix-credit-2" CREDIT 200.00
assert_field balanceAfter 270
echo 'PASS: credit 200 -> balance 270'
post_transaction 422 "$prefix-debit-rejected" DEBIT 100.00
assert_field code INSUFFICIENT_FUNDS
grep -qi '^Idempotent-Replayed: true' "$headers" || { echo 'Missing replay header' >&2; exit 1; }
echo 'PASS: rejected debit stays rejected on retry'
post_transaction 201 "$prefix-debit-1" DEBIT 30.00
assert_field balanceAfter 70
grep -qi '^Idempotent-Replayed: true' "$headers" || { echo 'Missing replay header' >&2; exit 1; }
echo 'PASS: applied debit replays historical balance'
post_transaction 409 "$prefix-debit-1" DEBIT 5.00
assert_field code IDEMPOTENCY_KEY_CONFLICT
echo 'PASS: changed payload -> 409'

http 200 -H "X-API-Key: $WALLET_API_KEY" \
  "$BASE_URL/wallets/$wallet_id/transactions?page=0&size=10"
assert_field totalElements 3
echo 'PASS: 3 applied transactions, no rejected entries in statement'
http 200 -H "X-API-Key: $WALLET_API_KEY" "$BASE_URL/wallets/$wallet_id"
assert_field balance 270
echo 'PASS: final balance = 270'

echo "C09 HTTP smoke test passed. Wallet $wallet_id remains in the DEVELOPMENT database."
