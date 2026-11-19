-- C06 - First use case in the database: create a wallet.
-- Runs through Flyway as WALLET_OWNER in FREEPDB1.
-- The package deliberately does NOT issue COMMIT or ROLLBACK.

-- Package specification: interface visible to permitted callers.
CREATE OR REPLACE PACKAGE pkg_wallet AUTHID DEFINER AS
    c_err_invalid_holder_name CONSTANT PLS_INTEGER := -20008;

    PROCEDURE create_wallet(
        p_holder_name IN  VARCHAR2,
        o_wallet_id   OUT NUMBER,
        o_balance     OUT NUMBER,
        o_created_at  OUT TIMESTAMP WITH TIME ZONE
    );
END pkg_wallet;
/

-- Package body: implementation executed with WALLET_OWNER privileges.
CREATE OR REPLACE PACKAGE BODY pkg_wallet AS

    PROCEDURE create_wallet(
        p_holder_name IN  VARCHAR2,
        o_wallet_id   OUT NUMBER,
        o_balance     OUT NUMBER,
        o_created_at  OUT TIMESTAMP WITH TIME ZONE
    ) IS
        -- Use a larger buffer to validate BEFORE writing to VARCHAR2(200 CHAR).
        v_holder_name VARCHAR2(32767);
        v_now         wallet.created_at%TYPE := SYSTIMESTAMP;
    BEGIN
        -- NULL is allowed (anonymous wallet). Oracle treats '' as NULL.
        -- A name with only spaces is not valid.
        IF p_holder_name IS NOT NULL THEN
            v_holder_name := TRIM(p_holder_name);

            IF v_holder_name IS NULL OR LENGTH(v_holder_name) > 200 THEN
                RAISE_APPLICATION_ERROR(
                    c_err_invalid_holder_name,
                    'Holder name must contain 1 to 200 characters'
                );
            END IF;
        END IF;

        -- The explicit sequence allocates the id. Initial balance is zero.
        -- RETURNING avoids a second SELECT to obtain the inserted values.
        INSERT INTO wallet (
            id,
            holder_name,
            balance,
            created_at,
            updated_at
        ) VALUES (
            seq_wallet.NEXTVAL,
            v_holder_name,
            0,
            v_now,
            v_now
        )
        RETURNING id, balance, created_at
        INTO o_wallet_id, o_balance, o_created_at;

        -- The caller owns the transaction boundary. NO COMMIT here.
    END create_wallet;

END pkg_wallet;
/

-- WALLET_APP may execute approved operations without direct table DML.
GRANT EXECUTE ON pkg_wallet TO WALLET_APP;
