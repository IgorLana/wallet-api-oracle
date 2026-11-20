/**
 * C12 — deterministic concurrent debit/idempotency workload.
 * Run ONLY via bash scripts/run-c12.sh on localhost. The wrapper creates and
 * funds an isolated development wallet, then reconciles Oracle state.
 *
 * Every iteration:
 * 1) POST a distinct DEBIT 1.00 using a globally unique idempotency key.
 * 2) POST the identical request and demand a historical replay, not new DML.
 *
 * Starting balance = C12_FUNDED_DEBITS (one BRL per funded debit).
 * With C12_ITERATIONS > funded debits, the final split is deterministic.
 */
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter, Rate } from 'k6/metrics';

const baseUrl = (__ENV.API_URL || 'http://localhost:8080').replace(/\/$/, '');
const walletId = __ENV.C12_WALLET_ID;
const runId = __ENV.C12_RUN_ID;
const iterations = Number(__ENV.C12_ITERATIONS || '40');
const vus = Number(__ENV.C12_VUS || '10');
const apiKey = __ENV.WALLET_API_KEY;

if (!walletId || !runId || !apiKey) {
    throw new Error('Missing C12_WALLET_ID, C12_RUN_ID or WALLET_API_KEY. Use scripts/run-c12.sh');
}

// HTTP 422 is the expected business outcome for an unfunded debit.
http.setResponseCallback(http.expectedStatuses(201, 422));

const applied = new Counter('c12_first_applied');
const rejected = new Counter('c12_first_rejected');
const exactReplay = new Rate('c12_exact_replay');

export const options = {
    scenarios: {
        concurrent_debits: {
            executor: 'shared-iterations',
            vus: vus,
            iterations: iterations,
            maxDuration: '5m',
            gracefulStop: '30s',
        },
    },
    thresholds: {
        checks: ['rate==1'],
        http_req_failed: ['rate==0'],
        http_req_duration: ['p(95)<10000'],
        c12_exact_replay: ['rate==1'],
    },
};

function header(response, wanted) {
    const found = Object.keys(response.headers).find((key) => key.toLowerCase() === wanted.toLowerCase());
    return found ? String(response.headers[found]).toLowerCase() : '';
}

export default function () {
    const iteration = exec.scenario.iterationInTest;
    const key = `${runId}-debit-${iteration}`;
    const url = `${baseUrl}/wallets/${walletId}/transactions`;
    const body = JSON.stringify({ type: 'DEBIT', amount: 1.00 });
    const params = {
        headers: {
            'Content-Type': 'application/json',
            'X-API-Key': apiKey,
            'Idempotency-Key': key,
        },
        timeout: '20s',
        tags: { operation: 'c12_debit' },
    };

    const first = http.post(url, body, params);
    const firstExpected = first.status === 201 || first.status === 422;
    let firstJson;
    try { firstJson = first.json(); } catch (e) { firstJson = null; }

    const nonnegative = first.status !== 201 ||
        (firstJson && Number(firstJson.balanceAfter) >= 0);
    const firstHeader = header(first, 'Idempotent-Replayed');
    const isNew = firstHeader === 'false';
    check(first, {
        'new debit gets a business outcome (201/422)': () => firstExpected,
        'new debit is not a replay': () => firstExpected && isNew,
        'applied debit never returns negative balance': () => !!nonnegative,
    });

    if (!firstExpected || !isNew || !nonnegative) {
        console.error(`Unexpected first response for iteration ${iteration}: HTTP ${first.status}`);
        exactReplay.add(false);
        return;
    }
    if (first.status === 201) applied.add(1);
    else rejected.add(1);

    // Verify actual server replay, not just unique constraints in Oracle.
    const repeated = http.post(url, body, params);
    const sameStatus = repeated.status === first.status;
    const replayHeader = header(repeated, 'Idempotent-Replayed') === 'true';
    const sameBody = repeated.body === first.body;
    const matched = sameStatus && replayHeader && sameBody;

    check(repeated, {
        'retry returns identical HTTP status': () => sameStatus,
        'retry advertises Idempotent-Replayed: true': () => replayHeader,
        'retry returns identical JSON body': () => sameBody,
    });
    exactReplay.add(matched);
    if (!matched) {
        console.error(`Replay mismatch for iteration ${iteration}: first=${first.status}, replay=${repeated.status}`);
    }
}
