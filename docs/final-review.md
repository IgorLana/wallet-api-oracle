# Technical requirements review (C12) (evidence and limitations)

Source: original 6-page PDF "Teste Tecnico - Desenvolvedor(a) Java com Oracle Database: Servico de Carteira Digital (Wallet API)". This document compares the requirements with the current repository implementation, not an independent production certification. Verify all commands on a fresh clone before submitting.

## Requirement matrix

| Requirement | Evidence in repo | Assessment |
| --- | --- | --- |
| Java 17+ and Spring Boot REST | `pom.xml` Java 21, Boot 4.1.2; `WalletController` | Implemented |
| Create, read, credit/debit, paginated statement | Four endpoints in `WalletController`; `WalletJdbcRepository` | Implemented |
| BRL 2 decimals, positive amount, no overdraft | `NUMBER(19,2)`, CHECK constraints; V5 PL/SQL validation and wallet lock | Implemented, tested |
| Oracle Free in Docker, pinned tag and healthcheck | `docker-compose.yml` | Implemented |
| Schemas with least privilege | `db/bootstrap/create-users.sh`, `audit/V1`, `owner/V3`, `owner/V4` | Implemented |
| All financial mutations in PL/SQL package | `owner/V5__pkg_wallet_transactions.sql` | Implemented |
| Explicit sequences | `owner/V1`, `audit/V1` | Implemented |
| Immutable applied ledger | `owner/V6__wallet_triggers.sql` | DML UPDATE/DELETE blocked while trigger enabled |
| Audit old/new balances, operation and time in separate schema | `audit/V1`, `owner/V6` | Implemented; direct unlinked changes use NULL operation ID |
| Concurrency on same wallet | `FOR UPDATE WAIT 5`; `WalletOracleIT` | Covered by integration tests |
| Idempotency across retries | Global PK request, V5 replay handling, `WalletOracleIT` | Implemented with documented race/timeout caveats |
| Unit and real Oracle integration tests | `WalletServiceTest`, `GlobalExceptionHandlerTest`, `WalletControllerTest`, `WalletOracleIT` | Verified on developer macOS through C10; rerun after C12 changes |
| Swagger/OpenAPI | springdoc 3.2.0, `OpenApiConfig`, controller annotations | C11 smoke test passed locally (reported by project owner) |
| API key | `ApiKeyFilter`, `WALLET_API_KEY` | Implemented for `/wallets` |
| Database migrations versioned | Separate Flyway Compose services and migration directories | Automated in the default Docker Compose startup; manual script still available |
| Documented errors and technical decisions | `GlobalExceptionHandler`, README, `DECISIONS.md` | Implemented with noted exception below |
| GitHub public with author-owned commit history | Repository workflow | Candidate must verify prior to submission |
| Load/concurrency test | `load/k6/c12-wallet.js`, `scripts/run-c12.sh`, `verify-c12-oracle.sh`, `docs/load-test-results.md` | C12 local test and reconciliation passed (reported by project owner); report includes verified balances and counts |

## Important transparent differences and limitations

### 1. Insufficient-funds PL/SQL signal is a returned REJECTED result

The PDF requests business errors from PL/SQL through `RAISE_APPLICATION_ERROR(-20000..-20999)`. Most invalid inputs and conflicts are raised this way. However, for insufficient funds V5 **returns** `status='REJECTED'`, `rejection_code='INSUFFICIENT_FUNDS'` rather than raising `-20004`. Spring commits that rejected request record and the controller translates it into HTTP 422. The design makes rejected retries stable even after the balance changes, but differs from the literal Oracle error-signaling requirement. This should be acknowledged in review and explained in the evaluation.

### 2. Database startup is now managed by Docker Compose

`docker compose up --build` starts Oracle and runs the existing SYSDBA bootstrap as an Oracle startup script. Two one-shot Flyway services then migrate `WALLET_AUDIT` and `WALLET_OWNER` in order. The Spring Boot container starts only after both migration stages succeed. The original `bash db/scripts/migrate.sh` path remains available for manual development. Existing database volumes keep their original schema passwords; the script does not silently reset them. Verify this new infrastructure path on a clean clone before relying on it.

### 3. Idempotency under simultaneous retries

Same wallet operations are serialized by a wallet row lock. A unique key stops double application even across wallets. Cross-wallet use of a key is a **different logical payload** (wallet ID is part of the identity) and is a conflict. On certain concurrent unique-key insertion races the losing caller receives a conflict rather than a historical replay; on wallet lock timeout the caller receives a retryable error. Additional retry-after-commit and contention tests are useful before claiming an exactly identical first response in every possible race.

### 4. Audit and immutability security limits

The auditor records `transaction_id=NULL` for a direct balance UPDATE when no new linked transaction ID is supplied; it cannot honestly point to a financial operation that did not exist. DML triggers can stop UPDATE/DELETE from normal sessions but are not invulnerable to sufficiently privileged DDL operations or a malicious DBA. The API user has no direct DML or audit access.

### 5. Test isolation and deployment

`./mvnw verify` uses a disposable Oracle and original SQL DDL run through SQL*Plus; this is a strong integration test of the database logic but does not validate Flyway metadata in that disposable instance. The normal local bootstrap does exercise Flyway separately. No CI/CD pipeline, production secret manager, TLS termination, or application health/metrics endpoint has been added. A Java multi-stage Dockerfile and Compose orchestration are provided for isolated local use. C12 adds an optional local k6 load/concurrency check, not a production SLA. `X-API-Key` is a system-to-system credential; deploy behind HTTPS in a real environment.

## Verification provenance

The project owner reported successful `./mvnw -U verify` with Oracle Testcontainers,
C08 Oracle checks, C11 Swagger/OpenAPI smoke checks and C12 k6/Oracle reconciliation
on macOS. `docs/load-test-results.md` contains the verified C12 ledger and audit
counts, although some performance metrics were not exported by the runner.

The full **Docker-only** startup is new in this delivery. The configuration has
been statically inspected, but a clean-clone execution of `docker compose up
--build` has not yet been verified by the author on Windows/macOS/Linux.
Do not present this check as completed until actual execution confirms it.

## Pre-submission checklist

- [ ] Fresh clone on Windows/macOS/Linux: `docker compose up --build`, no `.env` required; inspect `docker compose ps -a`.
- [ ] Optionally run `verify-c04.sh` through `verify-c08.sh` from a Bash-capable development terminal.
- [ ] Run `./mvnw -U verify` with Docker Desktop available and inspect reports.
- [ ] Confirm containerized API started after both Flyway services exited successfully (`docker compose logs`).
- [ ] Check `/swagger-ui.html` and `/v3/api-docs` and run `bash scripts/verify-c11.sh`.
- [ ] Exercise one credit and one insufficient-funds debit via Swagger or curl.
- [ ] Check DB data consistency and no unintended committed test data.
- [ ] Optional C12: run `bash scripts/run-c12.sh`, inspect PASS in k6/Oracle output, and commit `docs/load-test-results.md` containing measured metrics only after passing.
- [ ] Confirm `.env` is ignored, no credentials/secret values appear in tracked files.
- [ ] Verify public repository access from an unauthenticated browser.
- [ ] Verify `git log --format='%h %an <%ae> %s'` shows the candidate's commit identity.
- [ ] Send the repository link with the exact required subject and recipient from the PDF.

## What I would do with more time

1. Make bootstrap + migrations fully compose-native (or run migrations in a release pipeline).
2. Specify and test global-key retry behavior for every concurrency race and timeout.
3. Evaluate Oracle stronger immutability/audit-storage options and administrative separation.
4. Add a production deployment profile with secrets/TLS/observability.
5. Extend C12 beyond short concurrent smoke runs to sustained, multi-wallet stress tests with resource metrics.
