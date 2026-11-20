# C12 - Actual local load-test result

> Generated after **both** k6 thresholds and Oracle reconciliation PASSED. Test only on
> a local disposable-purpose development wallet; data persists in the development DB.

- **UTC execution date:** 2026-11-20T02:47:08+00:00
- **Run ID:** `c12-20261120024705-6215`
- **Wallet ID:** `45`
- **Tool:** Grafana k6, Oracle Database Free, Spring Boot application
- **Concurrent VUs:** 10
- **Distinct debit operations:** 40 (each repeated once using its idempotency key)
- **Initial credit:** BRL 20.00
- **Oracle verified:** 20 debits APPLIED, 20 debits REJECTED, balance BRL 0.00
- **Oracle verified ledger rows:** 21 (including the initial credit)
- **Oracle verified audit rows:** 21, one per ledger entry; no negative balances

## Observed k6 measurements

| Metric | Observed value |
| --- | ---: |
| Total HTTP requests | not reported |
| Mean HTTP response time (ms) | not reported |
| P95 HTTP response time (ms) | not reported |
| P99 HTTP response time (ms) | not reported |
| HTTP request rate (req/s) | not reported |
| Failed HTTP request rate | not reported |
| Check success rate | not reported |

Thresholds: `checks == 100%`, `http_req_failed == 0%`, `exact replay == 100%`,
`http_req_duration p95 < 10,000 ms`.
HTTP 422 insufficient-funds is an **expected business outcome**, not a transport failure.

## Reproduce

```bash
bash scripts/run-c12.sh
```

Original k6 JSON and Oracle output are stored in the local ignored
`reports/c12/c12-20261120024705-6215/` directory.
These measurements are **local functional/concurrency evidence**, not a production SLA.
