#!/usr/bin/env bash
# C12: LOCAL-ONLY load test and independent Oracle reconciliation.
# Run after the API has started: bash scripts/run-c12.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[[ -f .env ]] || { echo 'Missing .env. Run: cp .env.example .env' >&2; exit 2; }
set -a
# shellcheck disable=SC1091
source ./.env
set +a
: "${WALLET_API_KEY:?Set WALLET_API_KEY in .env}"

command -v docker >/dev/null || { echo 'Docker CLI required' >&2; exit 2; }
command -v k6 >/dev/null || { echo 'k6 missing. On macOS: brew install k6' >&2; exit 2; }
command -v python3 >/dev/null || { echo 'Python 3 required' >&2; exit 2; }

C12_ITERATIONS="${C12_ITERATIONS:-40}"
C12_VUS="${C12_VUS:-10}"
C12_FUNDED_DEBITS="${C12_FUNDED_DEBITS:-20}"
API_URL="${API_URL:-http://localhost:${SERVER_PORT:-8080}}"

for variable in C12_ITERATIONS C12_VUS C12_FUNDED_DEBITS; do
    if [[ ! "${!variable}" =~ ^[1-9][0-9]*$ ]] || (( ${!variable} < 1 || ${!variable} > 2000 )); then
        printf '%s must be a positive integer <= 2000\n' "$variable" >&2
        exit 2
    fi
done
if (( C12_ITERATIONS <= C12_FUNDED_DEBITS || C12_VUS < 2 || C12_VUS > C12_ITERATIONS )); then
    echo 'Require C12_ITERATIONS > C12_FUNDED_DEBITS >= 1 and 2 <= C12_VUS <= C12_ITERATIONS' >&2
    exit 2
fi
# Never run the load script against non-local environments by accident.
if [[ ! "$API_URL" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?/?$ ]]; then
    printf 'C12 is LOCAL-ONLY; refusing API_URL=%s\n' "$API_URL" >&2
    exit 2
fi
# Do not run multiple C12 instances simultaneously on the same development database.
C12_RUN_ID="c12-$(date -u +%Y%m%d%H%M%S)-$$"
REPORT_DIR="$ROOT/reports/c12/$C12_RUN_ID"
mkdir -p "$REPORT_DIR"
export API_URL C12_RUN_ID C12_ITERATIONS C12_VUS C12_FUNDED_DEBITS REPORT_DIR

printf '\nC12 LOCAL load test: %s\n' "$C12_RUN_ID"
printf '  Virtual users: %s\n  Unique debit requests: %s\n  Funded debits: %s\n' \
    "$C12_VUS" "$C12_ITERATIONS" "$C12_FUNDED_DEBITS"
printf '  Reports: %s\n' "$REPORT_DIR"
printf '  WARNING: creates a new wallet and PERSISTS data in local Oracle.\n\n'

docker compose exec -T oracle bash -c 'true' >/dev/null

# Use Python stdlib; no jq, third-party Python packages, or manual wallet ID.
C12_WALLET_ID="$(python3 - "$API_URL" "$C12_RUN_ID" "$C12_FUNDED_DEBITS" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

base, run_id, funds = sys.argv[1], sys.argv[2], int(sys.argv[3])
api_key = os.environ['WALLET_API_KEY']

def post(path, payload, extra=None):
    headers = {'Content-Type': 'application/json', 'X-API-Key': api_key}
    if extra:
        headers.update(extra)
    req = urllib.request.Request(base.rstrip('/') + path,
                                 data=json.dumps(payload).encode('utf-8'),
                                 headers=headers, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode('utf-8', errors='replace')[:500]
        raise RuntimeError(f'HTTP {exc.code} during C12 setup ({path}): {detail}') from exc

status, wallet = post('/wallets', {'holderName': 'C12 demo load ' + run_id})
if status != 201 or not isinstance(wallet.get('id'), int):
    raise RuntimeError(f'Unexpected wallet creation result: HTTP {status}')
wallet_id = wallet['id']
status, credit = post(f'/wallets/{wallet_id}/transactions',
                      {'type': 'CREDIT', 'amount': funds},
                      {'Idempotency-Key': run_id + '-seed'})
if status != 201 or float(credit.get('balanceAfter', -1)) != funds:
    raise RuntimeError(f'Unexpected credit result: HTTP {status}')
print(wallet_id)
PY
)"
if [[ ! "$C12_WALLET_ID" =~ ^[0-9]+$ ]]; then
    echo 'Invalid wallet ID returned by API setup' >&2
    exit 1
fi
export C12_WALLET_ID
printf 'PASS: prepared wallet %s with BRL %s.00\n' "$C12_WALLET_ID" "$C12_FUNDED_DEBITS"
printf '\nExecuting k6 with concurrent debit requests and exact retries...\n'

set +e
k6 run --summary-export "$REPORT_DIR/k6-summary.json" \
    --summary-trend-stats="avg,min,med,max,p(90),p(95),p(99)" \
    "$ROOT/load/k6/c12-wallet.js" 2>&1 | tee "$REPORT_DIR/k6-output.log"
k6_status=${PIPESTATUS[0]}
set -e

printf '\nIndependently reconciling committed Oracle state...\n'
set +e
bash "$ROOT/scripts/verify-c12-oracle.sh" 2>&1 | tee "$REPORT_DIR/oracle-validation.log"
oracle_status=${PIPESTATUS[0]}
set -e

if (( k6_status != 0 || oracle_status != 0 )); then
    printf '\nC12 FAILED (k6=%s, Oracle=%s). Keep reports in %s\n' \
        "$k6_status" "$oracle_status" "$REPORT_DIR" >&2
    echo 'The test wallet persists; do not delete the Oracle volume to retry.' >&2
    exit 1
fi

# Update a tracked, factual performance report only after both validations PASS.
python3 - "$REPORT_DIR/k6-summary.json" "$ROOT/docs/load-test-results.md" <<'PY'
import datetime
import json
import os
from pathlib import Path
import sys

summary = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
metrics = summary.get('metrics', {})

def metric(key, value):
    raw = metrics.get(key, {}).get('values', {}).get(value)
    return 'not reported' if raw is None else f'{raw:.2f}' if isinstance(raw, (float, int)) else str(raw)

n = int(os.environ['C12_ITERATIONS'])
funded = int(os.environ['C12_FUNDED_DEBITS'])
text = f'''# C12 - Actual local load-test result

> Generated after **both** k6 thresholds and Oracle reconciliation PASSED. Test only on
> a local disposable-purpose development wallet; data persists in the development DB.

- **UTC execution date:** {datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')}
- **Run ID:** `{os.environ['C12_RUN_ID']}`
- **Wallet ID:** `{os.environ['C12_WALLET_ID']}`
- **Tool:** Grafana k6, Oracle Database Free, Spring Boot application
- **Concurrent VUs:** {os.environ['C12_VUS']}
- **Distinct debit operations:** {n} (each repeated once using its idempotency key)
- **Initial credit:** BRL {funded}.00
- **Oracle verified:** {funded} debits APPLIED, {n-funded} debits REJECTED, balance BRL 0.00
- **Oracle verified ledger rows:** {funded+1} (including the initial credit)
- **Oracle verified audit rows:** {funded+1}, one per ledger entry; no negative balances

## Observed k6 measurements

| Metric | Observed value |
| --- | ---: |
| Total HTTP requests | {metric('http_reqs','count')} |
| Mean HTTP response time (ms) | {metric('http_req_duration','avg')} |
| P95 HTTP response time (ms) | {metric('http_req_duration','p(95)')} |
| P99 HTTP response time (ms) | {metric('http_req_duration','p(99)')} |
| HTTP request rate (req/s) | {metric('http_reqs','rate')} |
| Failed HTTP request rate | {metric('http_req_failed','rate')} |
| Check success rate | {metric('checks','rate')} |

Thresholds: `checks == 100%`, `http_req_failed == 0%`, `exact replay == 100%`,
`http_req_duration p95 < 10,000 ms`.
HTTP 422 insufficient-funds is an **expected business outcome**, not a transport failure.

## Reproduce

```bash
bash scripts/run-c12.sh
```

Original k6 JSON and Oracle output are stored in the local ignored
`reports/c12/{os.environ['C12_RUN_ID']}/` directory.
These measurements are **local functional/concurrency evidence**, not a production SLA.
'''
Path(sys.argv[2]).write_text(text, encoding='utf-8')
print(f'PASS: wrote measured report to {sys.argv[2]}')
PY

printf '\nC12 VERIFIED. Review docs/load-test-results.md and commit the real measurements.\n'
