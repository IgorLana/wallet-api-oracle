# C09 - Spring Boot / Oracle JDBC HTTP API

This commit connects Spring Boot 4.1.2 (Java 21) to the existing PL/SQL package,
views and Oracle Free instance. It assumes the migrations through V6 are already
applied and `db/scripts/verify-c07.sh` / `verify-c08.sh` pass.

## Local setup

1. Start Docker Desktop; run `bash db/scripts/migrate.sh`.
2. Confirm V6 is installed: `bash db/scripts/verify-c08.sh`.
3. Keep the existing `.env`, adding `WALLET_API_KEY=WalletApiLocalKey_2026_N3r7P5`.
   That example key is **for local development only**. Do not commit `.env`.
4. In your project root, execute:

   ```bash
   set -a
   source ./.env
   set +a
   ./mvnw clean verify
   ./mvnw spring-boot:run
   ```

   When running in your IDE, add `WALLET_APP_PASSWORD` and `WALLET_API_KEY`
   as environment variables to your run configuration.

The runtime JDBC user is **WALLET_APP**, not WALLET_OWNER or WALLET_AUDIT.
The application does not use Flyway or auto-create tables on startup.

## API contract

All four routes require `X-API-Key`.

### Create wallet

```bash
curl -i -X POST http://localhost:8080/wallets \
  -H "X-API-Key: $WALLET_API_KEY" -H 'Content-Type: application/json' \
  -d '{"holderName":"Ana"}'
```

Returns **201 Created**, `Location: /wallets/<id>` and the stored wallet.
`holderName` is optional (e.g. `{}` or empty body). Validation of a nonblank
non-null name and the maximum 200 characters is authoritative in PL/SQL.

### Get wallet

```bash
curl -i http://localhost:8080/wallets/1 -H "X-API-Key: $WALLET_API_KEY"
```

Returns **200** or **404**.

### Credit / debit

```bash
curl -i -X POST http://localhost:8080/wallets/1/transactions \
  -H "X-API-Key: $WALLET_API_KEY" -H 'Idempotency-Key: charge-001' \
  -H 'Content-Type: application/json' -d '{"type":"CREDIT","amount":100.00}'
```

The request fields are `type` (CREDIT/DEBIT) and `amount` (decimal, positive,
maximum two decimal places). Expected statuses:

- **201 Created** for new `APPLIED` operations; **201** on applied replay,
  same historical transaction ID, balance and timestamp, with `Idempotent-Replayed: true`.
- **422 Unprocessable Entity** for `REJECTED` due to insufficient funds. The
  procedure returns a terminal business result, so `WalletService` can COMMIT
  the idempotency record. The controller then returns 422. Repeating the same
  key/payload returns the original rejection, even after subsequent credits.
- **409 Conflict** for a key reused with a different payload.
- **503 Service Unavailable** for wallet lock timeout.

**Important transaction boundary:** Do NOT throw a rollback-triggering exception
from `WalletService.registerTransaction` when the package returns `REJECTED`.
The database result must COMMIT first; the controller formats the 422 after the
service's transactional proxy has returned.

### Paginated statement

```bash
curl -i -G 'http://localhost:8080/wallets/1/transactions' \
  -H "X-API-Key: $WALLET_API_KEY" \
  --data-urlencode 'page=0' --data-urlencode 'size=20' \
  --data-urlencode 'from=2026-01-01T00:00:00Z' \
  --data-urlencode 'to=2027-01-01T00:00:00Z'
```

Filters: `page` starts at zero; `size` 1..100; `from` inclusive, `to`
exclusive. Timestamps require an offset (e.g. `Z` or `-03:00`) and queries
sort by `created_at DESC, id DESC`. Results contain only applied ledger rows.

Errors use `{"code":"...","message":"...","status":...,"timestamp":"..."}`.
No SQL, passwords or stack traces are returned to HTTP clients.

## Code structure

- `config/ApiKeyFilter`: restricts `/wallets` paths using X-API-Key.
- `controller/WalletController`: defines routes, HTTP status, headers and DTOs.
- `service/WalletService`: business orchestration and @Transactional boundary.
- `repository/WalletJdbcRepository`: only procedure calls + SELECT from views.
- `exception/GlobalExceptionHandler`: maps `ORA-200xx` and request errors to HTTP.
- `model/`: database/result records; `dto/`: external JSON records.

## Smoke test

Run the API first, then `bash scripts/verify-c09.sh` in another terminal.
The script requires `curl` and `python3` and **creates permanent development
wallet data**, unlike the SQL-only rollback-based scripts. Do not run it against
production or an environment you want to keep unchanged.

## Operational limitations

1. Local verification reported on macOS: `./mvnw -U verify` completed
   successfully after correcting the SQL*Plus SQLBLANKLINES setup in the
   Testcontainers bootstrap. Reproduce on your own system before relying on it.
2. C07 currently maps a cross-wallet simultaneous duplicate-key insertion to
   conflict even when its payload matches. Strong concurrent replay semantics
   require a dedicated regression test and, if needed, a later PL/SQL migration.
3. Security is a simple system-to-system API key, not user authorization. Use
   HTTPS in a deployed environment; this test binds Oracle only to localhost.
4. Swagger/OpenAPI is in C11; JUnit and Testcontainers are in C10. The optional k6 concurrency check is C12.
5. C07 models insufficient funds as a returned REJECTED status, rather than
   `RAISE_APPLICATION_ERROR(-20004)`, to preserve the rejected request on commit.
   This intentional trade-off must remain documented for the evaluator.
