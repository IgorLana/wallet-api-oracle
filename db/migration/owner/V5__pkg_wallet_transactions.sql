-- C07: credits, debits, idempotency and row-level locking.
-- Flyway connection: WALLET_OWNER / FREEPDB1.
-- IMPORTANT: No COMMIT, ROLLBACK or AUTONOMOUS_TRANSACTION inside this package.
-- A rejected debit returns a terminal business result instead of raising -20004,
-- allowing its idempotency record to be committed by the caller.

CREATE OR REPLACE PACKAGE pkg_wallet AUTHID DEFINER AS
    c_err_invalid_amount       CONSTANT PLS_INTEGER := -20001;
    c_err_invalid_type         CONSTANT PLS_INTEGER := -20002;
    c_err_wallet_not_found     CONSTANT PLS_INTEGER := -20003;
    c_err_insufficient_funds   CONSTANT PLS_INTEGER := -20004; -- reserved; see docs
    c_err_idempotency_conflict CONSTANT PLS_INTEGER := -20005;
    c_err_wallet_busy          CONSTANT PLS_INTEGER := -20006;
    c_err_invalid_idem_key     CONSTANT PLS_INTEGER := -20007;
    c_err_invalid_holder_name  CONSTANT PLS_INTEGER := -20008;
    c_err_request_incomplete   CONSTANT PLS_INTEGER := -20009;

    PROCEDURE create_wallet(
        p_holder_name IN  VARCHAR2,
        o_wallet_id   OUT NUMBER,
        o_balance     OUT NUMBER,
        o_created_at  OUT TIMESTAMP WITH TIME ZONE
    );

    PROCEDURE register_transaction(
        p_wallet_id       IN  NUMBER,
        p_idempotency_key IN  VARCHAR2,
        p_type            IN  VARCHAR2,
        p_amount          IN  NUMBER,
        o_transaction_id  OUT NUMBER,
        o_balance_after   OUT NUMBER,
        o_result_status   OUT VARCHAR2,
        o_rejection_code  OUT VARCHAR2,
        o_completed_at    OUT TIMESTAMP WITH TIME ZONE,
        o_replayed        OUT VARCHAR2
    );
END pkg_wallet;
/

CREATE OR REPLACE PACKAGE BODY pkg_wallet AS

    -- Preserved from C06: wallet creation remains available.
    PROCEDURE create_wallet(
        p_holder_name IN  VARCHAR2,
        o_wallet_id   OUT NUMBER,
        o_balance     OUT NUMBER,
        o_created_at  OUT TIMESTAMP WITH TIME ZONE
    ) IS
        v_holder_name VARCHAR2(32767);
        v_now         wallet.created_at%TYPE := SYSTIMESTAMP;
    BEGIN
        IF p_holder_name IS NOT NULL THEN
            v_holder_name := TRIM(p_holder_name);
            IF v_holder_name IS NULL OR LENGTH(v_holder_name) > 200 THEN
                RAISE_APPLICATION_ERROR(
                    c_err_invalid_holder_name,
                    'Holder name must contain 1 to 200 characters'
                );
            END IF;
        END IF;

        INSERT INTO wallet (id, holder_name, balance, created_at, updated_at)
        VALUES (seq_wallet.NEXTVAL, v_holder_name, 0, v_now, v_now)
        RETURNING id, balance, created_at
        INTO o_wallet_id, o_balance, o_created_at;
    END create_wallet;

    PROCEDURE register_transaction(
        p_wallet_id       IN  NUMBER,
        p_idempotency_key IN  VARCHAR2,
        p_type            IN  VARCHAR2,
        p_amount          IN  NUMBER,
        o_transaction_id  OUT NUMBER,
        o_balance_after   OUT NUMBER,
        o_result_status   OUT VARCHAR2,
        o_rejection_code  OUT VARCHAR2,
        o_completed_at    OUT TIMESTAMP WITH TIME ZONE,
        o_replayed        OUT VARCHAR2
    ) IS
        v_balance         wallet.balance%TYPE;
        v_new_balance     NUMBER; -- unbounded during arithmetic; validate before writing NUMBER(19,2)
        v_now             wallet.created_at%TYPE;
        v_transaction_id  wallet_transaction.id%TYPE;
        v_existing        BOOLEAN := FALSE;
        v_existing_wallet wallet_operation_request.wallet_id%TYPE;
        v_existing_type   wallet_operation_request.transaction_type%TYPE;
        v_existing_amount wallet_operation_request.amount%TYPE;
        v_existing_status wallet_operation_request.status%TYPE;
        v_existing_code   wallet_operation_request.rejection_code%TYPE;
        v_existing_time   wallet_operation_request.completed_at%TYPE;
    BEGIN
        -- Initialize OUT parameters. They are undefined if an exception escapes.
        o_transaction_id := NULL;
        o_balance_after  := NULL;
        o_result_status  := NULL;
        o_rejection_code := NULL;
        o_completed_at   := NULL;
        o_replayed       := 'N';

        -- Validate inputs inside Oracle, even if Java will also validate them.
        IF p_wallet_id IS NULL OR p_wallet_id <= 0
           OR p_wallet_id <> TRUNC(p_wallet_id) THEN
            RAISE_APPLICATION_ERROR(c_err_wallet_not_found, 'Wallet not found');
        END IF;

        IF p_type IS NULL OR p_type NOT IN ('CREDIT', 'DEBIT') THEN
            RAISE_APPLICATION_ERROR(c_err_invalid_type, 'Type must be CREDIT or DEBIT');
        END IF;

        IF p_amount IS NULL OR p_amount <= 0
           OR p_amount <> TRUNC(p_amount, 2)
           OR p_amount >= 100000000000000000 THEN
            RAISE_APPLICATION_ERROR(
                c_err_invalid_amount, 'Amount must be positive and have at most 2 decimals'
            );
        END IF;

        IF p_idempotency_key IS NULL
           OR TRIM(p_idempotency_key) IS NULL
           OR LENGTH(p_idempotency_key) > 100
           OR p_idempotency_key <> TRIM(p_idempotency_key) THEN
            RAISE_APPLICATION_ERROR(c_err_invalid_idem_key, 'Invalid Idempotency-Key');
        END IF;

        -- Serialize modifications to THIS wallet, waiting at most 5 seconds.
        BEGIN
            SELECT balance INTO v_balance
              FROM wallet
             WHERE id = p_wallet_id
             FOR UPDATE WAIT 5;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(c_err_wallet_not_found, 'Wallet not found');
            WHEN OTHERS THEN
                IF SQLCODE IN (-30006, -54) THEN
                    RAISE_APPLICATION_ERROR(c_err_wallet_busy, 'Wallet is busy; retry with same key');
                ELSE
                    RAISE;
                END IF;
        END;

        -- After acquiring the lock, inspect previously COMMITTED requests.
        BEGIN
            SELECT wallet_id, transaction_type, amount, status,
                   rejection_code, completed_at
              INTO v_existing_wallet, v_existing_type, v_existing_amount,
                   v_existing_status, v_existing_code, v_existing_time
              FROM wallet_operation_request
             WHERE idempotency_key = p_idempotency_key;
            v_existing := TRUE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_existing := FALSE;
        END;

        IF v_existing THEN
            IF v_existing_wallet <> p_wallet_id
               OR v_existing_type <> p_type
               OR v_existing_amount <> p_amount THEN
                RAISE_APPLICATION_ERROR(
                    c_err_idempotency_conflict, 'Idempotency-Key used with different request'
                );
            END IF;

            IF v_existing_status = 'PENDING' THEN
                RAISE_APPLICATION_ERROR(
                    c_err_request_incomplete, 'Existing request has not been finalized'
                );
            END IF;

            o_result_status  := v_existing_status;
            o_rejection_code := v_existing_code;
            o_completed_at   := v_existing_time;
            o_replayed       := 'Y';

            IF v_existing_status = 'APPLIED' THEN
                SELECT id, balance_after
                  INTO o_transaction_id, o_balance_after
                  FROM wallet_transaction
                 WHERE idempotency_key = p_idempotency_key;
            ELSIF v_existing_status = 'REJECTED' THEN
                o_transaction_id := NULL;
                o_balance_after  := NULL;
            ELSE
                RAISE_APPLICATION_ERROR(c_err_request_incomplete, 'Unknown request status');
            END IF;
            RETURN;
        END IF;

        -- Only new keys reach this point. All terminal fields use one timestamp.
        v_now := SYSTIMESTAMP;

        -- Store insufficient-funds rejection AS DATA, no DML on the wallet.
        -- Do not RAISE here: the caller must COMMIT the rejection for durable replay.
        IF p_type = 'DEBIT' AND p_amount > v_balance THEN
            BEGIN
                INSERT INTO wallet_operation_request (
                    idempotency_key, wallet_id, transaction_type, amount,
                    status, rejection_code, created_at, completed_at
                ) VALUES (
                    p_idempotency_key, p_wallet_id, p_type, p_amount,
                    'REJECTED', 'INSUFFICIENT_FUNDS', v_now, v_now
                );
            EXCEPTION
                WHEN DUP_VAL_ON_INDEX THEN
                    RAISE_APPLICATION_ERROR(
                        c_err_idempotency_conflict, 'Idempotency-Key concurrently claimed'
                    );
            END;

            o_result_status  := 'REJECTED';
            o_rejection_code := 'INSUFFICIENT_FUNDS';
            o_completed_at   := v_now;
            RETURN;
        END IF;

        -- Calculate the final amount only after the lock has been obtained.
        IF p_type = 'CREDIT' THEN
            v_new_balance := v_balance + p_amount;
        ELSE
            v_new_balance := v_balance - p_amount;
        END IF;

        IF v_new_balance >= 100000000000000000 THEN
            RAISE_APPLICATION_ERROR(c_err_invalid_amount, 'Resulting balance exceeds precision');
        END IF;

        -- Reserve the globally unique key; cross-wallet concurrent inserts are
        -- serialized by the PRIMARY KEY constraint even without a wallet-row lock.
        BEGIN
            INSERT INTO wallet_operation_request (
                idempotency_key, wallet_id, transaction_type, amount,
                status, rejection_code, created_at, completed_at
            ) VALUES (
                p_idempotency_key, p_wallet_id, p_type, p_amount,
                'APPLIED', NULL, v_now, v_now
            );
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                RAISE_APPLICATION_ERROR(
                    c_err_idempotency_conflict, 'Idempotency-Key concurrently claimed'
                );
        END;

        v_transaction_id := seq_wallet_transaction.NEXTVAL;

        INSERT INTO wallet_transaction (
            id, wallet_id, idempotency_key, transaction_type,
            amount, balance_after, created_at
        ) VALUES (
            v_transaction_id, p_wallet_id, p_idempotency_key, p_type,
            p_amount, v_new_balance, v_now
        );

        UPDATE wallet
           SET balance             = v_new_balance,
               last_transaction_id = v_transaction_id,
               updated_at          = v_now
         WHERE id = p_wallet_id;

        o_transaction_id := v_transaction_id;
        o_balance_after  := v_new_balance;
        o_result_status  := 'APPLIED';
        o_completed_at   := v_now;
    END register_transaction;

END pkg_wallet;
/

-- Recreating the specification keeps the public EXECUTE grant explicit.
GRANT EXECUTE ON pkg_wallet TO WALLET_APP;
