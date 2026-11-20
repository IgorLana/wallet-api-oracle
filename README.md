# Wallet API | Java 21 + Spring Boot + Oracle PL/SQL

REST service for BRL digital wallets. Financial invariants are enforced in Oracle Database Free through a PL/SQL package, explicit sequences, constraints and triggers. Spring Boot exposes an HTTP API using a restricted database account.

> Technical exercise. No frontend, end-user accounts, transfers, exchange rates or chargebacks.

## 1. Requirements

- Java 21 (`java -version`)
- Docker Desktop / Docker Compose (allocate at least 4 GiB to Docker for Oracle Free)
- Bash-compatible terminal (macOS, Linux or Windows WSL2)
- Internet access to obtain the Docker images and Maven dependencies on first run
- `curl` for the manual HTTP examples; Python 3 for the optional HTTP smoke scripts

Maven installation is not required: the repository includes the Maven Wrapper (`./mvnw`). The database image is pinned to `gvenzl/oracle-free:23.26.4-slim-faststart`.

## 2. Start from a fresh clone

```bash
git clone https://github.com/IgorLana/wallet-api-oracle.git
cd wallet-api-oracle
cp .env.example .env
```

Edit **`.env`** (never commit it). Supply five different, non-default values:

```dotenv
ORACLE_PASSWORD=REPLACE_WITH_VALID_LOCAL_SECRET
WALLET_OWNER_PASSWORD=REPLACE_WITH_VALID_LOCAL_SECRET
WALLET_APP_PASSWORD=REPLACE_WITH_VALID_LOCAL_SECRET
WALLET_AUDIT_PASSWORD=REPLACE_WITH_VALID_LOCAL_SECRET
WALLET_API_KEY=REPLACE_WITH_LONG_API_KEY
```

The schema passwords must be **different** and contain 12-64 characters, begin with a letter, and use letters, numbers or underscores only. The API key must contain at least 16 characters. These placeholders are illustrative; use your own secrets. Once an Oracle Docker volume exists, changing `ORACLE_PASSWORD` does not automatically change the password already stored in the database.

Start Oracle, create the schemas and apply versioned migrations:

```bash
bash db/scripts/migrate.sh
```

This script starts the persistent Oracle container, bootstraps users as SYSDBA inside the container, runs Flyway for `WALLET_AUDIT` and then for `WALLET_OWNER`. It can be rerun; Flyway will skip previously applied versions.

Validate the schema and database behavior:

```bash
bash db/scripts/verify-c04.sh
bash db/scripts/verify-c05.sh
bash db/scripts/verify-c06.sh
bash db/scripts/verify-c07.sh
bash db/scripts/verify-c08.sh
```

Note: `verify-c08.sh` tests as local SYSDBA to inspect both schemas. The application itself **never** uses this account. No `docker compose down -v` is required or recommended: that command would delete persisted local Oracle data.

Export your local configuration to the shell and start the app:

```bash
set -a
source ./.env
set +a
./mvnw -U spring-boot:run
```

The application is available at `http://localhost:8080`. It uses `WALLET_APP` and will fail to start if the required database password or API key is absent. On Windows use WSL2 or another compatible Bash environment.

## 3. Swagger / OpenAPI

With Spring Boot running:

- Interactive UI: http://localhost:8080/swagger-ui.html
- OpenAPI JSON: http://localhost:8080/v3/api-docs
- OpenAPI YAML: http://localhost:8080/v3/api-docs.yaml

Use **Authorize** in Swagger UI and enter the `WALLET_API_KEY` value from your local `.env`. The `X-API-Key` header protects `/wallets` endpoints. The API documentation routes are public in the local development setup; do not place secrets in the OpenAPI description.

Check the generated API description without creating financial data:

```bash
bash scripts/verify-c11.sh
```

The API must already be running in another terminal.

## 4. HTTP contract

All wallet routes require `X-API-Key`. A transaction POST additionally requires `Idempotency-Key` and JSON `{ "type": "CREDIT|DEBIT", "amount": 0.01 }`.

| Method | Route | Success | Notes |
| --- | --- | --- | --- |
| POST | `/wallets` | 201 | Optional JSON `{ "holderName": "Ana" }`; starts with `0.00` |
| GET | `/wallets/{id}` | 200 | 404 when not found |
| POST | `/wallets/{id}/transactions` | 201 | Applied CREDIT/DEBIT; 422 for insufficient funds; 409 key conflict |
| GET | `/wallets/{id}/transactions` | 200 | `page` (0-based), `size` (1..100), `from` inclusive and `to` exclusive |

Financial amounts are positive BRL values with a maximum of two decimal places. The ledger is sorted by `created_at DESC, id DESC`. Rejected attempts do not appear in the financial statement.

### Example session

In a second terminal, load `.env` again:

```bash
set -a; source ./.env; set +a
curl -i -X POST http://localhost:8080/wallets \
  -H "X-API-Key: $WALLET_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"holderName":"Ana"}'
```

Read the returned `id` and set `WALLET_ID` to that actual value:

```bash
WALLET_ID=1 # replace with the id returned by POST /wallets
curl -i -X POST "http://localhost:8080/wallets/$WALLET_ID/transactions" \
  -H "X-API-Key: $WALLET_API_KEY" \
  -H 'Idempotency-Key: example-credit-001' \
  -H 'Content-Type: application/json' \
  -d '{"type":"CREDIT","amount":100.00}'

curl -i "http://localhost:8080/wallets/$WALLET_ID" \
  -H "X-API-Key: $WALLET_API_KEY"

curl -i "http://localhost:8080/wallets/$WALLET_ID/transactions?page=0&size=20" \
  -H "X-API-Key: $WALLET_API_KEY"
```

Repeating the transaction POST with the same key and payload returns the **original** applied transaction and `Idempotent-Replayed: true`, without another balance change. A different wallet/type/amount using that key returns `409`.

If a debit has insufficient funds, the API returns **422** and records a `REJECTED` request. A later retry with that same key and payload returns the historical rejection even after another credit. To make a new attempt, use a new key.

Sample error payload:

```json
{
  "code": "INSUFFICIENT_FUNDS",
  "message": "Insufficient funds",
  "status": 422,
  "timestamp": "2026-11-19T21:00:00Z"
}
```

For the full code mapping see `docs/api-local.md` and `docs/final-review.md`. The timestamp shown is only an example.

## 5. Architecture and database objects

```text
HTTP client -- X-API-Key --> Spring Controller
                                  |
                                  v
                            WalletService
                            @Transactional
                                  |
                                  v
                            JDBC Repository
                       CALL package / READ views
                                  |
                                  v
Oracle FREEPDB1: WALLET_OWNER.PKG_WALLET
  |-- WALLET                       (current balance)
  |-- WALLET_OPERATION_REQUEST     (applied/rejected attempts; global key)
  |-- WALLET_TRANSACTION           (immutable applied ledger)
  |-- V_WALLET, V_WALLET_TRANSACTION (read-only API projection)
  |-- SEQ_WALLET, SEQ_WALLET_TRANSACTION
  |-- TRG_WALLET_TRANSACTION_IMMUTABLE
  `-- TRG_WALLET_BALANCE_AUDIT ----> WALLET_AUDIT.BALANCE_AUDIT
```

Three Oracle accounts:

- `WALLET_OWNER`: owner of tables, views, sequences, procedures and triggers. Executes domain migrations.
- `WALLET_APP`: API account. `CREATE SESSION`, `EXECUTE` on the package, `READ` on the views; no direct DML on domain tables or access to audit.
- `WALLET_AUDIT`: owns the append-oriented balance audit table. The owner gets only the required `INSERT` and sequence `SELECT` grants.

The data model uses constraints (PK, FK, UNIQUE and CHECK) to enforce integrity. `WALLET.balance` is materialized for fast reads. Every applied credit/debit records one immutable ledger row and one audit entry via a row-level trigger; direct balance changes are also audited with `transaction_id` null if no new transaction id is supplied.

### Concurrency and idempotency

`PKG_WALLET.REGISTER_TRANSACTION` locks the wallet row with `SELECT ... FOR UPDATE WAIT 5`. The lock is held until the caller commits or rolls back. That serializes competing updates to the same wallet. A global primary key on `WALLET_OPERATION_REQUEST.idempotency_key` prevents duplicate effects across wallets. The original request payload and result are compared before replay. The database enforces a nonnegative balance as an additional constraint.

The Spring service controls transaction boundaries; the PL/SQL package does **not** call COMMIT/ROLLBACK. For insufficient funds, the package returns a terminal `REJECTED` result instead of raising `ORA-20004`, so the Spring transaction can **commit the rejection** before the controller responds HTTP 422. This is an intentional trade-off against the exercise's literal error-signaling preference; details in `docs/final-review.md`.

The ledger trigger blocks SQL UPDATE/DELETE while enabled. Privileged administrators with DDL capabilities are not prevented from disabling triggers or dropping objects; this is not a WORM database.

### Migrations

- Audit Flyway: `db/migration/audit/V1__balance_audit_and_grants.sql`
- Owner Flyway: `db/migration/owner/V1` through `V6` (sequences, tables, views, package, triggers)
- Bootstrap: `db/bootstrap/create-users.sh`
- Orchestrator: `db/scripts/migrate.sh`

Flyway runs outside the Spring application and the Spring runtime user does not have DDL privileges. The database `docker-compose.yml` alone starts Oracle; it does **not** run the schema bootstrap until `migrate.sh` is invoked.

## 6. Tests

```bash
./mvnw -U test       # fast JUnit/Mockito tests; Docker not required
./mvnw -U verify     # includes integration tests with disposable Oracle Testcontainers
```

Testcontainers starts an isolated Oracle instance. Its suite checks financial consistency, idempotency and replay, concurrent debits, database lock timeout, audit triggers, immutability, privileges and rollback. It applies the original SQL scripts via SQL*Plus; Flyway's history itself is checked separately by the normal `migrate.sh` workflow.

Reports: `target/surefire-reports/` and `target/failsafe-reports/`.

```bash
bash scripts/verify-c09.sh    # optional live HTTP test; creates persistent DEVELOPMENT data
bash scripts/verify-c11.sh    # Swagger/OpenAPI check; does not create wallet data
```

## 7. Decisions, limitations and review

- Architecture: [docs/architecture.md](docs/architecture.md)
- Decisions and alternatives: [DECISIONS.md](DECISIONS.md)
- Final requirements comparison and caveats: [docs/final-review.md](docs/final-review.md)
- Local setup: [docs/oracle-local.md](docs/oracle-local.md)
- Migrations: [docs/oracle-migrations.md](docs/oracle-migrations.md)
- API behavior: [docs/api-local.md](docs/api-local.md)
- Oracle integration tests: [docs/testing-c10.md](docs/testing-c10.md)
- Editable diagram: [docs/diagrams/wallet-architecture.excalidraw](docs/diagrams/wallet-architecture.excalidraw)

**What I would improve next:** run Flyway itself within disposable integration environments; add a containerized application profile; refine same-key retry behavior for rare races and timeouts; improve monitoring and operational metrics; consider stronger audit immutability controls beyond DML triggers; conduct k6 load testing. These are enhancements rather than claims of functionality already implemented.

## 8. Repository and submission

This project is intended to be submitted as a public GitHub repository with a series of traceable commits. Check that the repository URL is public, all files are committed and secrets are excluded. The original PDF requests an e-mail to **avaliacao.tech@datum.inf.br** with subject **Conclusão Avaliação – [Seu nome completo]**. Include the public GitHub repository link in the body. Verify the candidate name, deadline and sender identity before sending.
