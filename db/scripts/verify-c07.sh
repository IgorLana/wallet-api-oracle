#!/usr/bin/env bash
# C07 functional smoke test AS WALLET_APP; all test DML is rolled back.
# Usage: bash db/scripts/verify-c07.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  printf 'Missing .env\n' >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source ./.env
set +a
if [[ -z "${WALLET_APP_PASSWORD:-}" || "$WALLET_APP_PASSWORD" == 'CHANGE_ME' ]]; then
  printf 'Set WALLET_APP_PASSWORD in local .env first\n' >&2
  exit 1
fi

docker compose exec -T -e WALLET_APP_PASSWORD oracle bash -s <<'CONTAINER'
set -euo pipefail
sqlplus -L -s /nolog <<SQL
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET SERVEROUTPUT ON ECHO OFF VERIFY OFF FEEDBACK OFF
CONNECT WALLET_APP/"${WALLET_APP_PASSWORD}"@//localhost:1521/FREEPDB1

DECLARE
    v_wallet_id        NUMBER;
    v_wallet_balance   NUMBER;
    v_wallet_created   TIMESTAMP WITH TIME ZONE;
    v_tx_id            NUMBER;
    v_debit_tx_id      NUMBER;
    v_balance_after    NUMBER;
    v_status           VARCHAR2(10);
    v_code             VARCHAR2(40);
    v_completed        TIMESTAMP WITH TIME ZONE;
    v_debit_time       TIMESTAMP WITH TIME ZONE;
    v_rejected_time    TIMESTAMP WITH TIME ZONE;
    v_replayed         VARCHAR2(1);
    v_count            NUMBER;
    v_stored_balance   NUMBER;
BEGIN
    wallet_owner.pkg_wallet.create_wallet(
        'C07 rollback smoke', v_wallet_id, v_wallet_balance, v_wallet_created
    );

    wallet_owner.pkg_wallet.register_transaction(
        v_wallet_id, 'c07-credit-50', 'CREDIT', 50,
        v_tx_id, v_balance_after, v_status, v_code, v_completed, v_replayed
    );
    IF v_tx_id IS NULL OR v_status <> 'APPLIED' OR v_balance_after <> 50
       OR v_replayed <> 'N' OR v_code IS NOT NULL THEN
        RAISE_APPLICATION_ERROR(-20970, 'Credit 50 failed');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS credit 50 -> balance 50');

    wallet_owner.pkg_wallet.register_transaction(
        v_wallet_id, 'c07-debit-30', 'DEBIT', 30,
        v_tx_id, v_balance_after, v_status, v_code, v_completed, v_replayed
    );
    IF v_tx_id IS NULL OR v_status <> 'APPLIED' OR v_balance_after <> 20 THEN
        RAISE_APPLICATION_ERROR(-20971, 'Debit 30 failed');
    END IF;
    v_debit_tx_id := v_tx_id;
    v_debit_time  := v_completed;
    DBMS_OUTPUT.PUT_LINE('PASS debit 30 -> balance 20');

    wallet_owner.pkg_wallet.register_transaction(
        v_wallet_id, 'c07-denied-30', 'DEBIT', 30,
        v_tx_id, v_balance_after, v_status, v_code, v_completed, v_replayed
    );
    IF v_status <> 'REJECTED' OR v_code <> 'INSUFFICIENT_FUNDS'
       OR v_tx_id IS NOT NULL OR v_balance_after IS NOT NULL OR v_replayed <> 'N' THEN
        RAISE_APPLICATION_ERROR(-20972, 'Insufficient funds rejection failed');
    END IF;
    v_rejected_time := v_completed;
    DBMS_OUTPUT.PUT_LINE('PASS insufficient funds -> REJECTED, no transaction');

    wallet_owner.pkg_wallet.register_transaction(
        v_wallet_id, 'c07-credit-100', 'CREDIT', 100,
        v_tx_id, v_balance_after, v_status, v_code, v_completed, v_replayed
    );
    IF v_status <> 'APPLIED' OR v_balance_after <> 120 THEN
        RAISE_APPLICATION_ERROR(-20973, 'Credit 100 failed');
    END IF;

    wallet_owner.pkg_wallet.register_transaction(
        v_wallet_id, 'c07-denied-30', 'DEBIT', 30,
        v_tx_id, v_balance_after, v_status, v_code, v_completed, v_replayed
    );
    IF v_status <> 'REJECTED' OR v_code <> 'INSUFFICIENT_FUNDS'
       OR v_replayed <> 'Y' OR v_completed <> v_rejected_time
       OR v_tx_id IS NOT NULL THEN
        RAISE_APPLICATION_ERROR(-20974, 'Rejected request replay failed');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS rejected debit stays rejected after a new credit');

    wallet_owner.pkg_wallet.register_transaction(
        v_wallet_id, 'c07-debit-30', 'DEBIT', 30,
        v_tx_id, v_balance_after, v_status, v_code, v_completed, v_replayed
    );
    IF v_status <> 'APPLIED' OR v_tx_id <> v_debit_tx_id
       OR v_balance_after <> 20 OR v_replayed <> 'Y'
       OR v_completed <> v_debit_time THEN
        RAISE_APPLICATION_ERROR(-20975, 'Applied request replay failed');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS applied debit replays original id/balance/timestamp');

    BEGIN
        wallet_owner.pkg_wallet.register_transaction(
            v_wallet_id, 'c07-debit-30', 'DEBIT', 31,
            v_tx_id, v_balance_after, v_status, v_code, v_completed, v_replayed
        );
        RAISE_APPLICATION_ERROR(-20976, 'Conflict was accepted');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -20005 THEN RAISE; END IF;
    END;
    DBMS_OUTPUT.PUT_LINE('PASS same key with different amount -> -20005');

    BEGIN
        wallet_owner.pkg_wallet.register_transaction(
            v_wallet_id, 'c07-invalid-scale', 'CREDIT', 1.001,
            v_tx_id, v_balance_after, v_status, v_code, v_completed, v_replayed
        );
        RAISE_APPLICATION_ERROR(-20977, 'Three decimals were accepted');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -20001 THEN RAISE; END IF;
    END;
    DBMS_OUTPUT.PUT_LINE('PASS three decimal amount -> -20001');

    BEGIN
        wallet_owner.pkg_wallet.register_transaction(
            v_wallet_id, 'c07-invalid-type', 'TRANSFER', 1,
            v_tx_id, v_balance_after, v_status, v_code, v_completed, v_replayed
        );
        RAISE_APPLICATION_ERROR(-20978, 'Invalid type accepted');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -20002 THEN RAISE; END IF;
    END;
    DBMS_OUTPUT.PUT_LINE('PASS unsupported transaction type -> -20002');

    BEGIN
        wallet_owner.pkg_wallet.register_transaction(
            v_wallet_id, '   ', 'CREDIT', 1,
            v_tx_id, v_balance_after, v_status, v_code, v_completed, v_replayed
        );
        RAISE_APPLICATION_ERROR(-20979, 'Blank idem key accepted');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -20007 THEN RAISE; END IF;
    END;
    DBMS_OUTPUT.PUT_LINE('PASS blank key -> -20007');

    BEGIN
        wallet_owner.pkg_wallet.register_transaction(
            -1, 'c07-missing-wallet', 'CREDIT', 1,
            v_tx_id, v_balance_after, v_status, v_code, v_completed, v_replayed
        );
        RAISE_APPLICATION_ERROR(-20980, 'Invalid wallet accepted');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -20003 THEN RAISE; END IF;
    END;
    DBMS_OUTPUT.PUT_LINE('PASS invalid wallet -> -20003');

    SELECT COUNT(*) INTO v_count
      FROM wallet_owner.v_wallet_transaction
     WHERE wallet_id = v_wallet_id;
    SELECT balance INTO v_stored_balance
      FROM wallet_owner.v_wallet
     WHERE id = v_wallet_id;
    IF v_count <> 3 OR v_stored_balance <> 120 THEN
        RAISE_APPLICATION_ERROR(-20981, 'Inconsistent statement or wallet balance');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS statement has exactly 3 applied transactions');

    -- The procedure never issues COMMIT. Revert all smoke-test rows at once.
    ROLLBACK;
    SELECT COUNT(*) INTO v_count FROM wallet_owner.v_wallet WHERE id = v_wallet_id;
    IF v_count <> 0 THEN
        RAISE_APPLICATION_ERROR(-20982, 'Rollback did not remove created wallet');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS caller can rollback complete scenario');
    DBMS_OUTPUT.PUT_LINE('C07 smoke test passed; no test wallet persisted.');
END;
/
EXIT SUCCESS
SQL
CONTAINER
