-- This script runs as WALLET_AUDIT in the FREEPDB1 PDB.
-- The audit table is append-only for WALLET_OWNER: no UPDATE/DELETE privileges.
CREATE SEQUENCE seq_balance_audit
    START WITH 1
    INCREMENT BY 1
    CACHE 100
    NOCYCLE;

CREATE TABLE balance_audit (
    id             NUMBER(19) NOT NULL,
    wallet_id      NUMBER(19) NOT NULL,
    transaction_id NUMBER(19),
    old_balance    NUMBER(19,2) NOT NULL,
    new_balance    NUMBER(19,2) NOT NULL,
    changed_at     TIMESTAMP(6) WITH TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL,
    db_user        VARCHAR2(128 CHAR) NOT NULL,
    CONSTRAINT pk_balance_audit PRIMARY KEY (id),
    CONSTRAINT ck_balance_audit_old CHECK (old_balance >= 0),
    CONSTRAINT ck_balance_audit_new CHECK (new_balance >= 0)
);

-- Cross-schema privileges must be direct for definer-rights PL/SQL/triggers.
GRANT INSERT ON balance_audit TO WALLET_OWNER;
GRANT SELECT ON seq_balance_audit TO WALLET_OWNER;
