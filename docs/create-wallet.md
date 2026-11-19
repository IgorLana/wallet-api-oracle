# C06 - PKG_WALLET / create_wallet

## Scope

This commit introduces the first writable database use case without changing the
Spring Boot application. Only the `WALLET_OWNER.PKG_WALLET.CREATE_WALLET` procedure
is implemented. Credit/debit and idempotency will be added in later migrations.

## Files

- `db/migration/owner/V4__pkg_wallet_create.sql`: package specification, package
  body, and grant EXECUTE to WALLET_APP.
- `db/scripts/verify-c06.sh`: smoke tests through WALLET_APP, exercising the real
  package and read view while rolling back test data.

## Database contract

```sql
PROCEDURE create_wallet(
    p_holder_name IN  VARCHAR2,
    o_wallet_id   OUT NUMBER,
    o_balance     OUT NUMBER,
    o_created_at  OUT TIMESTAMP WITH TIME ZONE
);
```

Accepted input: NULL (anonymous wallet), or a holder name that contains
1 to 200 characters after trimming leading/trailing ASCII spaces. An all-space
name or name longer than 200 characters raises `ORA-20008`.
Oracle treats empty strings as NULL; empty input is therefore interpreted as
an absent optional holder.

On success, the package inserts `WALLET` using `SEQ_WALLET.NEXTVAL`, with
`balance=0` and the same `SYSTIMESTAMP` for `created_at` and `updated_at`.
`RETURNING INTO` obtains id, balance, and created timestamp without another query.

**Transaction ownership**: the package does not COMMIT or ROLLBACK. The caller
owns transaction boundaries (later, the Spring `@Transactional` service). A
smoke test runs a ROLLBACK and demonstrates that rows are not committed by the
procedure. Sequence increments are not rolled back and IDs can contain gaps.

**Security**: The package uses `AUTHID DEFINER`, so WALLET_APP needs only
EXECUTE on the package plus READ on `V_WALLET`. WALLET_APP receives no direct
DML permissions on `WALLET`.

**Audit**: creating an initial zero-balance wallet is not a balance change;
there is no balance audit event in this commit. The audit trigger is scheduled
for a later commit.

## How to run

Prerequisites: C05 has been migrated, Docker Desktop is running, and `.env`
contains working credentials for the existing Oracle accounts.

```bash
bash db/scripts/migrate.sh
bash db/scripts/verify-c06.sh
```

The Flyway owner schema should advance from version 3 to 4. Running migrate.sh
again should show no new migrations.

The smoke test authenticates as WALLET_APP and verifies:
1. A named wallet is created with `balance=0` and OUT parameters.
2. A NULL holder is allowed.
3. Whitespace-only names are rejected with ORA-20008.
4. Names longer than 200 characters are rejected with ORA-20008.
5. The inserted row is visible through V_WALLET and can be rolled back.

The smoke test consumes sequence values but leaves no committed test wallets.

## Next steps

- C07: extend package specification/body in a NEW migration for credit/debit,
  pessimistic lock and atomic ledger posting. Do not edit the applied V4 file.
- C08: finish idempotency for APPLIED and REJECTED operation requests, and add
  ledger immutability / balance audit triggers.
- C09: connect Java to the package via JDBC and implement HTTP endpoints.
