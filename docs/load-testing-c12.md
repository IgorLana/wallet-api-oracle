# C12 - Concurrent load test with k6 and independent Oracle reconciliation

This **optional** challenge enhancement verifies financial correctness under
concurrent HTTP requests. It is intentionally different from a generic latency
benchmark: every concurrent request is accountable in the database.

## Scope and safety

- **LOCAL DEVELOPMENT ONLY** (`http://localhost` or `http://127.0.0.1`).
- This test **writes persistent rows** to your local Oracle Compose volume.
  It creates a new wallet for every run. Never run against production or an
  existing wallet containing valuable data.
- The load script requires the already-running Spring Boot API, Docker
  Desktop, Python 3 and locally installed k6 (`brew install k6` on macOS).
- The verifier uses local container SYSDBA **read-only** SQL to inspect owner
  and audit schemas. The Spring Boot runtime continues to use WALLET_APP.
- Credentials come from the local, ignored `.env`; the public `.env.example`
  contains development-only values that **must not be deployed**.

## Run

```bash
# One-time setup after cloning a new repository:
cp .env.example .env
bash db/scripts/migrate.sh

# Terminal 1: start Spring Boot
set -a; source ./.env; set +a
./mvnw spring-boot:run

# Terminal 2:
brew install k6  # first time only on macOS
bash scripts/run-c12.sh
```

Default workload:

| Parameter | Value | Meaning |
| --- | ---: | --- |
| `C12_ITERATIONS` | 40 | Different debit requests, each with its own key |
| `C12_VUS` | 10 | Concurrent k6 virtual users |
| `C12_FUNDED_DEBITS` | 20 | Initial wallet credit in BRL; each debit is BRL 1.00 |
| API endpoint | `http://localhost:8080` | Only localhost is accepted |

Adjust an optional parameter without editing source code:

```bash
C12_VUS=5 C12_ITERATIONS=60 C12_FUNDED_DEBITS=30 bash scripts/run-c12.sh
```

Require `C12_ITERATIONS > C12_FUNDED_DEBITS >= 1` and
`2 <= C12_VUS <= C12_ITERATIONS`, with all values at most 2000.
Start with the defaults before increasing concurrency; Oracle uses a
`SELECT ... FOR UPDATE WAIT 5` lock timeout on each wallet.

## Workload and expected financial result

The orchestration script performs a **sequential setup**:

1. Creates one wallet using the real HTTP POST `/wallets` endpoint.
2. Credits the wallet with `C12_FUNDED_DEBITS` BRL using a unique idempotency key.
3. Starts k6 with `C12_VUS` concurrent VUs and exactly `C12_ITERATIONS`
   shared iterations. Iterations get unique, global `Idempotency-Key` values.
4. Every iteration sends a BRL 1.00 **DEBIT** and then repeats it with the
   **same payload and same key**. The second response must match the original
   status and JSON body and must contain `Idempotent-Replayed: true`.
5. After k6, independently verifies the final Oracle database state. The
   check runs even if the k6 command fails, to retain useful diagnostics.

For default parameters, expected results are:

| Financial property | Exact expected result |
| --- | ---: |
| Initial balance after one seed CREDIT | BRL 20.00 |
| Distinct concurrent DEBIT requests | 40 |
| DEBIT `APPLIED` (`201`) | 20 |
| DEBIT `REJECTED` (`422`) | 20 |
| Replay requests (same keys) | 40 |
| Final balance | BRL 0.00 |
| Ledger rows | 21 (1 credit + 20 debits) |
| Audit rows | 21 |
| Request rows | 41 (1 seed + 40 debit attempts) |
| Negative persisted balances | 0 |

The wallet row lock and Oracle constraints enforce these invariants. The
independent SQL verification checks counts, credits/debits, mathematical
balance, audit-to-ledger 1:1 mapping, absence of orphan/missing audits,
`PENDING` absence and absence of negative `balance_after` values.

A request returning `503` due to contention is treated as a **failed load
run**, not as a valid result; reduce VUs and rerun with a new wallet, or
investigate lock behavior. HTTP `422` is **expected** under these inputs and
is not treated as a transport failure by k6.

## Performance metrics and evidence

The k6 test collects normal HTTP metrics and enforces thresholds:

- 100% of client checks pass;
- 0% unexpected HTTP responses (201 and 422 are accepted);
- 100% exact idempotent replays;
- p95 HTTP response duration < 10 seconds (generous local smoke threshold).

On success, the script generates or updates:

- `docs/load-test-results.md` — **actual** measurements, date and verified
  final-state counts; commit this after reviewing the output.
- `reports/c12/<run-id>/k6-summary.json` — machine-readable summary.
- `reports/c12/<run-id>/k6-output.log` — full k6 terminal result.
- `reports/c12/<run-id>/oracle-validation.log` — Oracle verification output.

`reports/c12/` is ignored by Git. The tracked results page starts with a
**PENDING** marker and gets real numbers only after a successful execution.
No fabricated performance measurements are included in this commit.

## Limits and interpretation

This is a short fixed-iteration **concurrency correctness smoke test**, not a
capacity planning benchmark or production SLA. `shared-iterations` does not
guarantee a constant arrival rate or evenly distributed iterations per VU.
The sequence runs through a single hot wallet to make lock contention
meaningful. The test does not implement multi-wallet throughput, soak testing,
resource monitoring, TLS termination, retries after errors, or network fault
injection. The privileged SQL audit query is for local verification only.

The Oracle Testcontainers suite in C10 continues to provide disposable,
repeatable integration tests. C12 intentionally exercises the *running local
application* and creates an isolated wallet within the persistent local DB.
