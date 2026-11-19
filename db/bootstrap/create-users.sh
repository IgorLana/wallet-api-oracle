#!/usr/bin/env bash
# Runs INSIDE the Oracle container through: docker compose exec -T -e ... oracle bash -s
# SYSDBA is used only for the bootstrap, not for migrations or application traffic.
set -euo pipefail

validate_password() {
  local name="$1"
  local value="${!name:-}"
  # Intentionally small allowed alphabet: values are interpolated into SQL DDL.
  # No spaces, quotes, SQLPlus substitution characters, or shell metacharacters.
  if [[ ! "$value" =~ ^[A-Za-z][A-Za-z0-9_]{11,63}$ ]] || [[ "$value" == CHANGE_ME ]]; then
    printf 'Invalid %s: use 12-64 letters, digits, underscores; start with a letter.\n' "$name" >&2
    exit 1
  fi
}

validate_password WALLET_OWNER_PASSWORD
validate_password WALLET_APP_PASSWORD
validate_password WALLET_AUDIT_PASSWORD

if [[ "$WALLET_OWNER_PASSWORD" == "$WALLET_APP_PASSWORD" || "$WALLET_OWNER_PASSWORD" == "$WALLET_AUDIT_PASSWORD" || "$WALLET_APP_PASSWORD" == "$WALLET_AUDIT_PASSWORD" ]]; then
  printf 'Use distinct passwords for the three accounts.\n' >&2
  exit 1
fi

# Values are strictly validated above before being interpolated into SQL.
# If a user already exists, do NOT reset its password: reruns remain safe.
sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET ECHO OFF VERIFY OFF FEEDBACK ON SERVEROUTPUT ON
ALTER SESSION SET CONTAINER = FREEPDB1;

DECLARE
  PROCEDURE ensure_user(p_name IN VARCHAR2, p_password IN VARCHAR2) IS
    v_count NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_count FROM DBA_USERS WHERE USERNAME = p_name;
    IF v_count = 0 THEN
      EXECUTE IMMEDIATE 'CREATE USER ' || p_name ||
        ' IDENTIFIED BY "' || p_password || '"' ||
        ' DEFAULT TABLESPACE USERS TEMPORARY TABLESPACE TEMP';
      DBMS_OUTPUT.PUT_LINE('Created ' || p_name);
    ELSE
      DBMS_OUTPUT.PUT_LINE('Already exists: ' || p_name || ' (password unchanged)');
    END IF;
  END;
BEGIN
  ensure_user('WALLET_AUDIT', '${WALLET_AUDIT_PASSWORD}');
  ensure_user('WALLET_OWNER', '${WALLET_OWNER_PASSWORD}');
  ensure_user('WALLET_APP',   '${WALLET_APP_PASSWORD}');
END;
/

-- Only the audit schema owns the balance audit data.
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE TO WALLET_AUDIT;
ALTER USER WALLET_AUDIT QUOTA 100M ON USERS;

-- Owner has DDL for its own domain; no broad RESOURCE/DBA roles.
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE PROCEDURE, CREATE TRIGGER, CREATE VIEW TO WALLET_OWNER;
ALTER USER WALLET_OWNER QUOTA 100M ON USERS;

-- Application has no table DML, DDL, or audit access.
GRANT CREATE SESSION TO WALLET_APP;

SELECT USERNAME, ACCOUNT_STATUS FROM DBA_USERS
WHERE USERNAME IN ('WALLET_OWNER', 'WALLET_APP', 'WALLET_AUDIT')
ORDER BY USERNAME;
EXIT SUCCESS
SQL
