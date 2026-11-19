CREATE TABLE wallet
(
    id                  NUMBER(19) NOT NULL,
    holder_name         VARCHAR2(200 CHAR),
    balance             NUMBER(19,2) DEFAULT 0 NOT NULL,
    last_transaction_id NUMBER(19),

    created_at          TIMESTAMP(6) WITH TIME ZONE
        DEFAULT SYSTIMESTAMP NOT NULL,

    updated_at          TIMESTAMP(6) WITH TIME ZONE
        DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT pk_wallet
        PRIMARY KEY (id),

    CONSTRAINT ck_wallet_balance
        CHECK (balance >= 0)
);

CREATE TABLE wallet_operation_request
(
    idempotency_key  VARCHAR2(100 CHAR) NOT NULL,
    wallet_id        NUMBER(19) NOT NULL,
    transaction_type VARCHAR2(6 CHAR) NOT NULL,
    amount           NUMBER(19,2) NOT NULL,

    status           VARCHAR2(10 CHAR) DEFAULT 'PENDING' NOT NULL,
    rejection_code   VARCHAR2(40 CHAR),

    created_at       TIMESTAMP(6) WITH TIME ZONE
        DEFAULT SYSTIMESTAMP NOT NULL,

    completed_at     TIMESTAMP(6) WITH TIME ZONE,

    CONSTRAINT pk_wallet_operation_request
        PRIMARY KEY (idempotency_key),

    CONSTRAINT fk_operation_request_wallet
        FOREIGN KEY (wallet_id)
            REFERENCES wallet (id),

    CONSTRAINT ck_operation_request_type
        CHECK (transaction_type IN ('CREDIT', 'DEBIT')),

    CONSTRAINT ck_operation_request_amount
        CHECK (amount > 0),

    CONSTRAINT ck_operation_request_status
        CHECK (status IN ('PENDING', 'APPLIED', 'REJECTED')),

    CONSTRAINT ck_operation_request_lifecycle
        CHECK (
            (
                status = 'PENDING'
                    AND rejection_code IS NULL
                    AND completed_at IS NULL
                )
                OR
            (
                status = 'APPLIED'
                    AND rejection_code IS NULL
                    AND completed_at IS NOT NULL
                )
                OR
            (
                status = 'REJECTED'
                    AND rejection_code IS NOT NULL
                    AND completed_at IS NOT NULL
                )
            )
);


CREATE TABLE wallet_transaction
(
    id               NUMBER(19) NOT NULL,
    wallet_id        NUMBER(19) NOT NULL,
    idempotency_key  VARCHAR2(100 CHAR) NOT NULL,
    transaction_type VARCHAR2(6 CHAR) NOT NULL,
    amount           NUMBER(19,2) NOT NULL,
    balance_after    NUMBER(19,2) NOT NULL,

    created_at       TIMESTAMP(6) WITH TIME ZONE
        DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT pk_wallet_transaction
        PRIMARY KEY (id),

    CONSTRAINT fk_wallet_transaction_wallet
        FOREIGN KEY (wallet_id)
            REFERENCES wallet (id),

    CONSTRAINT fk_transaction_request
        FOREIGN KEY (idempotency_key)
            REFERENCES wallet_operation_request (idempotency_key),

    CONSTRAINT uk_wallet_transaction_request
        UNIQUE (idempotency_key),

    CONSTRAINT uk_wallet_transaction_wallet_id
        UNIQUE (wallet_id, id),

    CONSTRAINT ck_wallet_transaction_type
        CHECK (transaction_type IN ('CREDIT', 'DEBIT')),

    CONSTRAINT ck_wallet_transaction_amount
        CHECK (amount > 0),

    CONSTRAINT ck_wallet_transaction_balance
        CHECK (balance_after >= 0)
);

ALTER TABLE wallet
    ADD CONSTRAINT fk_wallet_last_transaction
        FOREIGN KEY (id, last_transaction_id)
            REFERENCES wallet_transaction (wallet_id, id);


CREATE INDEX ix_wallet_transaction_wallet_date
    ON wallet_transaction (
            wallet_id,
            created_at DESC,
            id DESC
        );

CREATE INDEX ix_operation_request_wallet_date
    ON wallet_operation_request (
            wallet_id,
            created_at DESC
        );