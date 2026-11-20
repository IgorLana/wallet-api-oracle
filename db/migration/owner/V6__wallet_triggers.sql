-- C08 - Balance auditing and immutable financial ledger.
-- Applied by Flyway as WALLET_OWNER, after V5 (register_transaction).
-- Required cross-schema privileges are already granted in audit/V1:
--   INSERT ON WALLET_AUDIT.BALANCE_AUDIT TO WALLET_OWNER
--   SELECT ON WALLET_AUDIT.SEQ_BALANCE_AUDIT TO WALLET_OWNER

-- Statement-level: block UPDATE/DELETE even if the WHERE matches zero rows.
-- Does not block INSERT, which is required by PKG_WALLET.
CREATE OR REPLACE TRIGGER trg_wallet_transaction_immutable
    BEFORE UPDATE OR DELETE ON wallet_transaction
BEGIN
    RAISE_APPLICATION_ERROR(
        -20030,
        'Financial ledger is immutable: UPDATE and DELETE are forbidden'
    );
END;
/

-- Row-level: one audit entry for each wallet row whose balance CHANGES.
-- This trigger executes in the SAME transaction as the balance UPDATE.
-- No COMMIT, ROLLBACK, or AUTONOMOUS_TRANSACTION here.
CREATE OR REPLACE TRIGGER trg_wallet_balance_audit
    AFTER UPDATE OF balance ON wallet
    FOR EACH ROW
    WHEN (OLD.balance <> NEW.balance)
DECLARE
    v_transaction_id wallet.last_transaction_id%TYPE;
BEGIN
    -- Do not falsely attribute direct SQL balance changes to an older
    -- transaction that happens to remain in LAST_TRANSACTION_ID.
    -- The package sets a NEW transaction ID together with each balance change.
    IF :NEW.last_transaction_id IS NOT NULL
       AND (
           :OLD.last_transaction_id IS NULL
           OR :OLD.last_transaction_id <> :NEW.last_transaction_id
       ) THEN
        v_transaction_id := :NEW.last_transaction_id;
    END IF;

    INSERT INTO wallet_audit.balance_audit (
        id,
        wallet_id,
        transaction_id,
        old_balance,
        new_balance,
        changed_at,
        db_user
    ) VALUES (
        wallet_audit.seq_balance_audit.NEXTVAL,
        :NEW.id,
        v_transaction_id,
        :OLD.balance,
        :NEW.balance,
        SYSTIMESTAMP,
        SYS_CONTEXT('USERENV', 'SESSION_USER')
    );
END;
/
