

CREATE OR REPLACE VIEW v_wallet AS
SELECT
    id,
    holder_name,
    balance,
    created_at,
    updated_at
FROM wallet;

CREATE OR REPLACE VIEW v_wallet_transaction AS
SELECT
    id,
    wallet_id,
    transaction_type,
    amount,
    balance_after,
    created_at
FROM wallet_transaction;

GRANT READ ON v_wallet TO WALLET_APP;

GRANT READ ON v_wallet_transaction TO WALLET_APP;