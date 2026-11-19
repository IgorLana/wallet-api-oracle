#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

docker compose exec -T oracle bash -s <<'CONTAINER'
set -euo pipefail

sqlplus -s / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET SERVEROUTPUT ON

ALTER SESSION SET CONTAINER = FREEPDB1;

DECLARE
    v_count NUMBER;
BEGIN

    -- Check required tables
    SELECT COUNT(*)
    INTO v_count
    FROM DBA_TABLES
    WHERE OWNER = 'WALLET_OWNER'
      AND TABLE_NAME IN (
          'WALLET',
          'WALLET_OPERATION_REQUEST',
          'WALLET_TRANSACTION'
      );

    IF v_count <> 3 THEN
        RAISE_APPLICATION_ERROR(
            -20090,
            'C05 verification failed: missing tables'
        );
    END IF;

    -- Check read views
    SELECT COUNT(*)
    INTO v_count
    FROM DBA_VIEWS
    WHERE OWNER = 'WALLET_OWNER'
      AND VIEW_NAME IN (
          'V_WALLET',
          'V_WALLET_TRANSACTION'
      );

    IF v_count <> 2 THEN
        RAISE_APPLICATION_ERROR(
            -20091,
            'C05 verification failed: missing views'
        );
    END IF;

    -- Check READ grants to WALLET_APP
    SELECT COUNT(*)
    INTO v_count
    FROM DBA_TAB_PRIVS
    WHERE OWNER = 'WALLET_OWNER'
      AND GRANTEE = 'WALLET_APP'
      AND PRIVILEGE = 'READ'
      AND TABLE_NAME IN (
          'V_WALLET',
          'V_WALLET_TRANSACTION'
      );

    IF v_count <> 2 THEN
        RAISE_APPLICATION_ERROR(
            -20092,
            'C05 verification failed: missing READ grants'
        );
    END IF;

    -- Check selected integrity constraints
    SELECT COUNT(*)
    INTO v_count
    FROM DBA_CONSTRAINTS
    WHERE OWNER = 'WALLET_OWNER'
      AND STATUS = 'ENABLED'
      AND CONSTRAINT_NAME IN (
          'PK_WALLET',
          'CK_WALLET_BALANCE',
          'PK_WALLET_OPERATION_REQUEST',
          'CK_OPERATION_REQUEST_LIFECYCLE',
          'PK_WALLET_TRANSACTION',
          'FK_WALLET_LAST_TRANSACTION',
          'UK_WALLET_TRANSACTION_REQUEST'
      );

    IF v_count <> 7 THEN
        RAISE_APPLICATION_ERROR(
            -20093,
            'C05 verification failed: missing constraints'
        );
    END IF;

    DBMS_OUTPUT.PUT_LINE(
        'C05 verification passed successfully.'
    );
END;
/

EXIT SUCCESS
SQL
CONTAINER