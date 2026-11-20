#!/usr/bin/env bash
# C12 - privileged, READ-ONLY reconciliation for a newly created demo wallet.
# Only scripts/run-c12.sh should invoke this with C12_* exported and validated.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for variable in C12_WALLET_ID C12_ITERATIONS C12_FUNDED_DEBITS; do
    if [[ ! "${!variable:-}" =~ ^[0-9]+$ ]]; then
        printf 'Missing or invalid %s (positive integer required)\n' "$variable" >&2
        exit 2
    fi
done

# The SYSDBA connection is inside the LOCAL Docker container; never in the API.
# The test wallet is disposable in purpose but rows persist in local development DB.
docker compose exec -T \
    -e C12_WALLET_ID -e C12_ITERATIONS -e C12_FUNDED_DEBITS \
    oracle bash -s <<'CONTAINER'
set -euo pipefail
sqlplus -L -s / as sysdba <<SQL
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET FEEDBACK OFF HEADING OFF VERIFY OFF PAGESIZE 0
ALTER SESSION SET CONTAINER = FREEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_wallet_id         NUMBER := ${C12_WALLET_ID};
    v_requests          NUMBER := ${C12_ITERATIONS};
    v_funded            NUMBER := ${C12_FUNDED_DEBITS};
    v_balance           NUMBER;
    v_count_wallet      NUMBER;
    v_ledger            NUMBER;
    v_credits           NUMBER;
    v_debits            NUMBER;
    v_applied_amount    NUMBER;
    v_debit_total      NUMBER;
    v_balance_from_ledger NUMBER;
    v_request_count     NUMBER;
    v_request_applied   NUMBER;
    v_request_rejected  NUMBER;
    v_request_pending   NUMBER;
    v_audit_count       NUMBER;
    v_bad_audit         NUMBER;
    v_bad_audit_values  NUMBER;
    v_orphan_audit      NUMBER;
    v_bad_requests      NUMBER;
    v_negative_count    NUMBER;
BEGIN
    SELECT COUNT(*), MAX(balance)
      INTO v_count_wallet, v_balance
      FROM wallet_owner.wallet
     WHERE id = v_wallet_id;
    IF v_count_wallet <> 1 OR v_balance <> 0 THEN
        RAISE_APPLICATION_ERROR(-20910, 'C12: expected one wallet with final balance 0');
    END IF;

    SELECT COUNT(*),
           COUNT(CASE WHEN transaction_type = 'CREDIT' THEN 1 END),
           COUNT(CASE WHEN transaction_type = 'DEBIT' THEN 1 END),
           NVL(SUM(CASE WHEN transaction_type = 'CREDIT' THEN amount ELSE 0 END),0),
           NVL(SUM(CASE WHEN transaction_type = 'DEBIT' THEN amount ELSE 0 END),0),
           NVL(SUM(CASE WHEN transaction_type = 'CREDIT' THEN amount ELSE -amount END),0),
           COUNT(CASE WHEN balance_after < 0 THEN 1 END)
      INTO v_ledger, v_credits, v_debits,
           v_applied_amount, v_debit_total, v_balance_from_ledger, v_negative_count
      FROM wallet_owner.wallet_transaction
     WHERE wallet_id = v_wallet_id;

    IF v_ledger <> v_funded + 1 OR v_credits <> 1 OR v_debits <> v_funded
       OR v_applied_amount <> v_funded OR v_debit_total <> v_funded
       OR v_balance_from_ledger <> v_balance OR v_negative_count <> 0 THEN
        RAISE_APPLICATION_ERROR(-20911, 'C12: ledger / current balance mismatch');
    END IF;

    SELECT COUNT(*),
           COUNT(CASE WHEN status = 'APPLIED' THEN 1 END),
           COUNT(CASE WHEN status = 'REJECTED' THEN 1 END),
           COUNT(CASE WHEN status = 'PENDING' THEN 1 END)
      INTO v_request_count, v_request_applied, v_request_rejected, v_request_pending
      FROM wallet_owner.wallet_operation_request
     WHERE wallet_id = v_wallet_id;

    IF v_request_count <> v_requests + 1
       OR v_request_applied <> v_funded + 1
       OR v_request_rejected <> v_requests - v_funded
       OR v_request_pending <> 0 THEN
        RAISE_APPLICATION_ERROR(-20912, 'C12: operation requests count/status mismatch');
    END IF;

    SELECT COUNT(*),
           COUNT(CASE WHEN new_balance < 0 THEN 1 END)
      INTO v_audit_count, v_negative_count
      FROM wallet_audit.balance_audit
     WHERE wallet_id = v_wallet_id;

    IF v_audit_count <> v_funded + 1 OR v_negative_count <> 0 THEN
        RAISE_APPLICATION_ERROR(-20913, 'C12: audit count or balance invalid');
    END IF;

    SELECT COUNT(*) INTO v_bad_audit
      FROM wallet_owner.wallet_transaction t
     WHERE t.wallet_id = v_wallet_id
       AND (SELECT COUNT(*) FROM wallet_audit.balance_audit a
             WHERE a.wallet_id = t.wallet_id AND a.transaction_id = t.id) <> 1;

    SELECT COUNT(*) INTO v_orphan_audit
      FROM wallet_audit.balance_audit a
     WHERE a.wallet_id = v_wallet_id
       AND NOT EXISTS (SELECT 1 FROM wallet_owner.wallet_transaction t
                        WHERE t.wallet_id = a.wallet_id AND t.id = a.transaction_id);

    -- Verify not only linkage but also the exact monetary change recorded.
    SELECT COUNT(*) INTO v_bad_audit_values
      FROM wallet_owner.wallet_transaction t
      JOIN wallet_audit.balance_audit a
        ON a.wallet_id = t.wallet_id AND a.transaction_id = t.id
     WHERE t.wallet_id = v_wallet_id
       AND (a.new_balance <> t.balance_after
            OR (t.transaction_type = 'CREDIT' AND a.new_balance - a.old_balance <> t.amount)
            OR (t.transaction_type = 'DEBIT' AND a.old_balance - a.new_balance <> t.amount));

    -- APPLIED must have a corresponding ledger row; REJECTED must not.
    SELECT COUNT(*) INTO v_bad_requests
      FROM wallet_owner.wallet_operation_request r
     WHERE r.wallet_id = v_wallet_id
       AND ((r.status = 'APPLIED' AND NOT EXISTS
             (SELECT 1 FROM wallet_owner.wallet_transaction t
               WHERE t.idempotency_key = r.idempotency_key))
            OR (r.status = 'REJECTED' AND EXISTS
             (SELECT 1 FROM wallet_owner.wallet_transaction t
               WHERE t.idempotency_key = r.idempotency_key)));

    IF v_bad_audit <> 0 OR v_orphan_audit <> 0
       OR v_bad_audit_values <> 0 OR v_bad_requests <> 0 THEN
        RAISE_APPLICATION_ERROR(-20914, 'C12: inconsistent audit or operation/ledger mapping');
    END IF;

    DBMS_OUTPUT.PUT_LINE('PASS: wallet final balance = 0.00; no overdraft');
    DBMS_OUTPUT.PUT_LINE('PASS: applied credits=1, debits=' || v_debits || ', ledger=' || v_ledger);
    DBMS_OUTPUT.PUT_LINE('PASS: rejected=' || v_request_rejected || ', APPLIED=' || v_request_applied || ', PENDING=0');
    DBMS_OUTPUT.PUT_LINE('PASS: audit=' || v_audit_count || ', 1:1 match with ledger, no missing/orphan rows');
    DBMS_OUTPUT.PUT_LINE('C12_ORACLE_PASS wallet=' || v_wallet_id ||
        ' debit_applied=' || v_debits || ' debit_rejected=' || v_request_rejected ||
        ' ledger=' || v_ledger || ' audit=' || v_audit_count || ' balance=' || v_balance);
END;
/
EXIT SUCCESS
SQL
CONTAINER
