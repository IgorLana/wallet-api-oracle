#!/usr/bin/env bash
# C08 Oracle integration smoke test for triggers. No committed test data.
# Run from anywhere: bash db/scripts/verify-c08.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# SYSDBA is used ONLY to inspect both OWNER and AUDIT schemas and to
# attempt direct DML. The application must continue to use WALLET_APP.
docker compose exec -T oracle bash -s <<'CONTAINER'
set -euo pipefail
sqlplus -L -s / as sysdba <<'SQL'
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

SET FEEDBACK ON
SET VERIFY OFF

-- Primeiro, mudar para o PDB
ALTER SESSION SET CONTAINER = FREEPDB1;

-- Depois, habilitar a saída neste container
SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT C08: Starting verification

DECLARE
    v_wallet_id      NUMBER;
    v_wallet_balance  NUMBER;
    v_created_at     TIMESTAMP WITH TIME ZONE;
    v_transaction_id NUMBER;
    v_credit_id      NUMBER;
    v_debit_id       NUMBER;
    v_balance_after  NUMBER;
    v_status         VARCHAR2(10);
    v_rejection_code VARCHAR2(40);
    v_completed_at   TIMESTAMP WITH TIME ZONE;
    v_replayed       VARCHAR2(1);
    v_count          NUMBER;
    v_audit_id       NUMBER;
    v_old_balance    NUMBER;
    v_new_balance    NUMBER;
    v_audit_tx_id    NUMBER;
    v_audit_user     VARCHAR2(128);
    v_audit_time     TIMESTAMP WITH TIME ZONE;
    v_amount         NUMBER;
    v_blocked        BOOLEAN;
BEGIN
    -- Check both trigger objects are compiled and enabled.
    SELECT COUNT(*) INTO v_count
      FROM DBA_OBJECTS o
      JOIN DBA_TRIGGERS t
        ON t.owner = o.owner AND t.trigger_name = o.object_name
     WHERE o.owner = 'WALLET_OWNER'
       AND o.object_type = 'TRIGGER'
       AND o.status = 'VALID'
       AND t.status = 'ENABLED'
       AND o.object_name IN (
           'TRG_WALLET_TRANSACTION_IMMUTABLE',
           'TRG_WALLET_BALANCE_AUDIT'
       );
    IF v_count <> 2 THEN
        RAISE_APPLICATION_ERROR(-20091, 'C08: triggers missing, invalid or disabled');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS: both triggers are VALID and ENABLED');

    -- Create a wallet through the package (no COMMIT).
    wallet_owner.pkg_wallet.create_wallet(
        'C08 Trigger Test', v_wallet_id, v_wallet_balance, v_created_at
    );
    IF v_wallet_balance <> 0 THEN
        RAISE_APPLICATION_ERROR(-20092, 'C08: initial balance is not zero');
    END IF;

    -- Credit 100. Expect exactly one audit entry, 0 -> 100.
    wallet_owner.pkg_wallet.register_transaction(
        v_wallet_id, 'c08-credit-unique', 'CREDIT', 100,
        v_transaction_id, v_balance_after, v_status, v_rejection_code,
        v_completed_at, v_replayed
    );
    v_credit_id := v_transaction_id;
    IF v_status <> 'APPLIED' OR v_balance_after <> 100 THEN
        RAISE_APPLICATION_ERROR(-20093, 'C08: credit failed');
    END IF;

    SELECT COUNT(*), MAX(old_balance), MAX(new_balance), MAX(transaction_id)
      INTO v_count, v_old_balance, v_new_balance, v_audit_tx_id
      FROM wallet_audit.balance_audit
     WHERE wallet_id = v_wallet_id;
    IF v_count <> 1 OR v_old_balance <> 0 OR v_new_balance <> 100
       OR v_audit_tx_id <> v_credit_id THEN
        RAISE_APPLICATION_ERROR(-20094, 'C08: credit audit does not match');
    END IF;
    SELECT db_user, changed_at
      INTO v_audit_user, v_audit_time
      FROM wallet_audit.balance_audit
     WHERE wallet_id = v_wallet_id
       AND transaction_id = v_credit_id;
    IF v_audit_user <> SYS_CONTEXT('USERENV', 'SESSION_USER')
       OR v_audit_time IS NULL THEN
        RAISE_APPLICATION_ERROR(-20057, 'C08: missing audit session user or timestamp');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS: credit 0 -> 100 produces one linked audit row');

    -- Debit 40. Expect audit 100 -> 60 linked to the new transaction.
    wallet_owner.pkg_wallet.register_transaction(
        v_wallet_id, 'c08-debit-unique', 'DEBIT', 40,
        v_transaction_id, v_balance_after, v_status, v_rejection_code,
        v_completed_at, v_replayed
    );
    v_debit_id := v_transaction_id;
    IF v_status <> 'APPLIED' OR v_balance_after <> 60 THEN
        RAISE_APPLICATION_ERROR(-20095, 'C08: debit failed');
    END IF;

    SELECT COUNT(*), MAX(old_balance), MAX(new_balance)
      INTO v_count, v_old_balance, v_new_balance
      FROM wallet_audit.balance_audit
     WHERE wallet_id = v_wallet_id
       AND transaction_id = v_debit_id;
    IF v_count <> 1 OR v_old_balance <> 100 OR v_new_balance <> 60 THEN
        RAISE_APPLICATION_ERROR(-20096, 'C08: debit audit does not match');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS: debit 100 -> 60 produces one linked audit row');

    -- Insufficient-funds rejection must not change wallet or create audit.
    wallet_owner.pkg_wallet.register_transaction(
        v_wallet_id, 'c08-rejected-unique', 'DEBIT', 1000,
        v_transaction_id, v_balance_after, v_status, v_rejection_code,
        v_completed_at, v_replayed
    );
    IF v_status <> 'REJECTED' OR v_rejection_code <> 'INSUFFICIENT_FUNDS' THEN
        RAISE_APPLICATION_ERROR(-20097, 'C08: rejection not returned');
    END IF;
    SELECT COUNT(*) INTO v_count
      FROM wallet_audit.balance_audit
     WHERE wallet_id = v_wallet_id;
    IF v_count <> 2 THEN
        RAISE_APPLICATION_ERROR(-20098, 'C08: rejected request produced audit');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS: rejected debit produces no balance audit');

    -- Updating metadata or writing an equal balance is not a change of balance.
    UPDATE wallet_owner.wallet
       SET updated_at = SYSTIMESTAMP
     WHERE id = v_wallet_id;
    UPDATE wallet_owner.wallet
       SET balance = balance
     WHERE id = v_wallet_id;
    SELECT COUNT(*) INTO v_count
      FROM wallet_audit.balance_audit
     WHERE wallet_id = v_wallet_id;
    IF v_count <> 2 THEN
        RAISE_APPLICATION_ERROR(-20099, 'C08: unchanged balance was audited');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS: no audit for metadata or unchanged balance');

    -- A direct balance modification is audited, but it must NOT be
    -- attributed to the previously recorded transaction ID.
    UPDATE wallet_owner.wallet
       SET balance = 59
     WHERE id = v_wallet_id;
    SELECT COUNT(*), MAX(old_balance), MAX(new_balance), MAX(transaction_id)
      INTO v_count, v_old_balance, v_new_balance, v_audit_tx_id
      FROM wallet_audit.balance_audit
     WHERE wallet_id = v_wallet_id
       AND old_balance = 60 AND new_balance = 59;
    IF v_count <> 1 OR v_audit_tx_id IS NOT NULL THEN
        RAISE_APPLICATION_ERROR(-20050, 'C08: direct update falsely linked to transaction');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS: direct balance UPDATE audited with transaction_id NULL');

    -- Attempt direct UPDATE to the immutable ledger.
    v_blocked := FALSE;
    BEGIN
        UPDATE wallet_owner.wallet_transaction
           SET amount = amount + 1
         WHERE id = v_debit_id;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -20030
               OR INSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 'ORA-20030') > 0 THEN
                v_blocked := TRUE;
            ELSE
                RAISE;
            END IF;
    END;
    IF NOT v_blocked THEN
        RAISE_APPLICATION_ERROR(-20051, 'C08: UPDATE on ledger was accepted');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS: direct UPDATE on ledger blocked (-20030)');

    -- Attempt direct DELETE to the immutable ledger.
    v_blocked := FALSE;
    BEGIN
        DELETE FROM wallet_owner.wallet_transaction
         WHERE id = v_debit_id;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -20030
               OR INSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 'ORA-20030') > 0 THEN
                v_blocked := TRUE;
            ELSE
                RAISE;
            END IF;
    END;
    IF NOT v_blocked THEN
        RAISE_APPLICATION_ERROR(-20052, 'C08: DELETE on ledger was accepted');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS: direct DELETE on ledger blocked (-20030)');

    SELECT amount INTO v_amount
      FROM wallet_owner.wallet_transaction
     WHERE id = v_debit_id;
    IF v_amount <> 40 THEN
        RAISE_APPLICATION_ERROR(-20053, 'C08: ledger amount was modified');
    END IF;

    -- Auditing is transactional: ROLLBACK removes wallet, ledger, request,
    -- and audit rows together. Sequence numbers may still have gaps.
    ROLLBACK;
    SELECT COUNT(*) INTO v_count
      FROM wallet_owner.wallet
     WHERE id = v_wallet_id;
    IF v_count <> 0 THEN
        RAISE_APPLICATION_ERROR(-20054, 'C08: wallet survived ROLLBACK');
    END IF;
    SELECT COUNT(*) INTO v_count
      FROM wallet_audit.balance_audit
     WHERE wallet_id = v_wallet_id;
    IF v_count <> 0 THEN
        RAISE_APPLICATION_ERROR(-20055, 'C08: audit survived ROLLBACK');
    END IF;
    SELECT COUNT(*) INTO v_count
      FROM wallet_owner.wallet_transaction
     WHERE wallet_id = v_wallet_id;
    IF v_count <> 0 THEN
        RAISE_APPLICATION_ERROR(-20056, 'C08: ledger survived ROLLBACK');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS: ROLLBACK removes wallet, ledger and audit together');
    DBMS_OUTPUT.PUT_LINE('C08 verification passed. No test data persisted.');
END;
/
EXIT SUCCESS
SQL
CONTAINER
