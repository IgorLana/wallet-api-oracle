#!/usr/bin/env bash
# C06 smoke test: calls the package AS WALLET_APP and rolls back test data.
# Usage from the repository root: bash db/scripts/verify-c06.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  printf 'Missing .env. Configure WALLET_APP_PASSWORD first.\n' >&2
  exit 1
fi

# The local .env is trusted Bash-compatible configuration, not remote input.
set -a
# shellcheck disable=SC1091
source ./.env
set +a

if [[ -z "${WALLET_APP_PASSWORD:-}" || "${WALLET_APP_PASSWORD}" == 'CHANGE_ME' ]]; then
  printf 'WALLET_APP_PASSWORD must be set in .env.\n' >&2
  exit 1
fi

# Do not pass the password as a process argument or echo it in the logs.
docker compose exec -T -e WALLET_APP_PASSWORD oracle bash -s <<'CONTAINER'
set -euo pipefail
sqlplus -L -s /nolog <<SQL
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET SERVEROUTPUT ON ECHO OFF VERIFY OFF FEEDBACK ON
CONNECT WALLET_APP/"${WALLET_APP_PASSWORD}"@//localhost:1521/FREEPDB1

DECLARE
    v_id          NUMBER;
    v_first_id    NUMBER;
    v_second_id   NUMBER;
    v_balance     NUMBER;
    v_created_at  TIMESTAMP WITH TIME ZONE;
    v_count       NUMBER;
    v_name        VARCHAR2(200 CHAR);
    v_stored_bal  NUMBER;
BEGIN
    -- Happy path. Only EXECUTE on the package and READ on the view are used.
    wallet_owner.pkg_wallet.create_wallet(
        p_holder_name => 'C06 Smoke Test',
        o_wallet_id   => v_id,
        o_balance     => v_balance,
        o_created_at  => v_created_at
    );

    IF v_id IS NULL OR v_balance <> 0 OR v_created_at IS NULL THEN
        RAISE_APPLICATION_ERROR(-20091, 'Invalid OUT parameters');
    END IF;

    SELECT COUNT(*), MAX(holder_name), MAX(balance)
      INTO v_count, v_name, v_stored_bal
      FROM wallet_owner.v_wallet
     WHERE id = v_id;

    IF v_count <> 1 OR v_name <> 'C06 Smoke Test' OR v_stored_bal <> 0 THEN
        RAISE_APPLICATION_ERROR(-20092, 'Inserted wallet not visible or incorrect');
    END IF;
    v_first_id := v_id;
    DBMS_OUTPUT.PUT_LINE('PASS: create wallet with initial zero balance');

    -- Optional holder: NULL is accepted.
    wallet_owner.pkg_wallet.create_wallet(NULL, v_id, v_balance, v_created_at);
    IF v_id IS NULL OR v_balance <> 0 THEN
        RAISE_APPLICATION_ERROR(-20093, 'Optional holder test failed');
    END IF;
    v_second_id := v_id;
    DBMS_OUTPUT.PUT_LINE('PASS: optional holder name');

    -- Invalid: spaces-only holder must return application error -20008.
    BEGIN
        wallet_owner.pkg_wallet.create_wallet('   ', v_id, v_balance, v_created_at);
        RAISE_APPLICATION_ERROR(-20094, 'Spaces-only holder was accepted');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -20008 THEN RAISE; END IF;
    END;
    DBMS_OUTPUT.PUT_LINE('PASS: reject spaces-only holder');

    -- Invalid: longer than the VARCHAR2(200 CHAR) column.
    BEGIN
        wallet_owner.pkg_wallet.create_wallet(RPAD('X', 201, 'X'), v_id, v_balance, v_created_at);
        RAISE_APPLICATION_ERROR(-20095, 'Overlong holder was accepted');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -20008 THEN RAISE; END IF;
    END;
    DBMS_OUTPUT.PUT_LINE('PASS: reject holder longer than 200 characters');

    -- No COMMIT in the package: test writes can be rolled back together.
    ROLLBACK;
    SELECT COUNT(*) INTO v_count
      FROM wallet_owner.v_wallet
     WHERE id IN (v_first_id, v_second_id);
    IF v_count <> 0 THEN
        RAISE_APPLICATION_ERROR(-20096, 'Rollback did not remove test wallet');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS: caller controls COMMIT/ROLLBACK');
    DBMS_OUTPUT.PUT_LINE('C06 verification passed. No test wallets persisted.');
END;
/
EXIT SUCCESS
SQL
CONTAINER
