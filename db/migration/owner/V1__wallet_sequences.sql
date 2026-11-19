-- This script runs as WALLET_OWNER in FREEPDB1.
-- IDs are not chronological and can have gaps after rollbacks or cache losses.
CREATE SEQUENCE seq_wallet
    START WITH 1
    INCREMENT BY 1
    CACHE 20
    NOCYCLE;

CREATE SEQUENCE seq_wallet_transaction
    START WITH 1
    INCREMENT BY 1
    CACHE 100
    NOCYCLE;
