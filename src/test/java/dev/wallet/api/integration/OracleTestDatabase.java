package dev.wallet.api.integration;

import org.testcontainers.containers.Container;
import org.testcontainers.utility.MountableFile;
import org.testcontainers.oracle.OracleContainer;

import java.io.IOException;
import java.nio.file.Path;
import java.time.Duration;

/**
 * Creates a NEW, disposable Oracle database for C10 integration tests.
 * Copies the existing C04-C08 SQL sources, preserving the real schema/privileges.
 * It NEVER connects to or modifies the developer's docker-compose database.
 */
final class OracleTestDatabase {
    static final String OWNER_PASSWORD = "OwnerC10Test2026_Q8x4";
    static final String APP_PASSWORD   = "AppC10Test2026_Q8x4";
    static final String AUDIT_PASSWORD = "AuditC10Test2026_Q8x4";
    static final String API_KEY        = "C10-Test-ApiKey-12345678";

    private static final OracleContainer ORACLE =
            new OracleContainer("gvenzl/oracle-free:23.26.4-slim-faststart")
                    .withUsername("TC_SETUP_USER")
                    .withPassword("TcSetup2026_Q8x4")
                    .withStartupTimeout(Duration.ofMinutes(6));

    private static boolean started;

    private OracleTestDatabase() {}

    static synchronized void start() {
        if (started) return;
        try {
            ORACLE.start();
            Path migrationRoot = Path.of("db").toAbsolutePath();
            ORACLE.copyFileToContainer(MountableFile.forHostPath(migrationRoot), "/tmp/wallet-c10-db");

            exec("export WALLET_OWNER_PASSWORD=" + OWNER_PASSWORD
                    + " WALLET_APP_PASSWORD=" + APP_PASSWORD
                    + " WALLET_AUDIT_PASSWORD=" + AUDIT_PASSWORD
                    + "; bash /tmp/wallet-c10-db/bootstrap/create-users.sh");

            runSql("WALLET_AUDIT", AUDIT_PASSWORD, "audit/V1__balance_audit_and_grants.sql");
            runSql("WALLET_OWNER", OWNER_PASSWORD, "owner/V1__wallet_sequences.sql");
            runSql("WALLET_OWNER", OWNER_PASSWORD, "owner/V2__wallet_tables.sql");
            runSql("WALLET_OWNER", OWNER_PASSWORD, "owner/V3__wallet_read_views.sql");
            runSql("WALLET_OWNER", OWNER_PASSWORD, "owner/V4__pkg_wallet_create.sql");
            runSql("WALLET_OWNER", OWNER_PASSWORD, "owner/V5__pkg_wallet_transactions.sql");
            runSql("WALLET_OWNER", OWNER_PASSWORD, "owner/V6__wallet_triggers.sql");

            // SQL*Plus can return success when a package compiles INVALID.
            // This assertion prevents false-positive test setup.
            // Use a standalone SQL file instead of shell-quoting SQL text.
            // Keep the file generated only inside this disposable container.
            exec("cat >/tmp/c10-check.sql <<'SQL'\n"
                    + "WHENEVER SQLERROR EXIT FAILURE\n"
                    + "ALTER SESSION SET CONTAINER = FREEPDB1;\n"
                    + "DECLARE\n  v_count NUMBER;\nBEGIN\n"
                    + "  SELECT COUNT(*) INTO v_count FROM DBA_OBJECTS\n"
                    + "  WHERE OWNER = 'WALLET_OWNER'\n"
                    + "    AND OBJECT_TYPE IN ('PACKAGE', 'PACKAGE BODY', 'TRIGGER', 'VIEW')\n"
                    + "    AND STATUS <> 'VALID';\n"
                    + "  IF v_count <> 0 THEN RAISE_APPLICATION_ERROR(-20999, 'Invalid PL/SQL objects'); END IF;\n"
                    + "  SELECT COUNT(*) INTO v_count FROM DBA_OBJECTS\n"
                    + "  WHERE OWNER = 'WALLET_OWNER' AND STATUS = 'VALID'\n"
                    + "    AND OBJECT_NAME IN ('PKG_WALLET', 'TRG_WALLET_TRANSACTION_IMMUTABLE',\n"
                    + "                        'TRG_WALLET_BALANCE_AUDIT', 'V_WALLET', 'V_WALLET_TRANSACTION')\n"
                    + "    AND OBJECT_TYPE IN ('PACKAGE', 'PACKAGE BODY', 'TRIGGER', 'VIEW');\n"
                    + "  IF v_count <> 6 THEN RAISE_APPLICATION_ERROR(-20998, 'Expected six valid SQL objects'); END IF;\n"
                    + "  SELECT COUNT(*) INTO v_count FROM DBA_TRIGGERS WHERE OWNER = 'WALLET_OWNER'\n"
                    + "    AND STATUS = 'ENABLED' AND TRIGGER_NAME IN\n"
                    + "    ('TRG_WALLET_TRANSACTION_IMMUTABLE', 'TRG_WALLET_BALANCE_AUDIT');\n"
                    + "  IF v_count <> 2 THEN RAISE_APPLICATION_ERROR(-20997, 'Triggers are not enabled'); END IF;\n"
                    + "END;\n/\nEXIT SUCCESS\nSQL\n"
                    + "sqlplus -L -s / as sysdba < /tmp/c10-check.sql");
            started = true;
        } catch (Exception failure) {
            ORACLE.stop();
            throw new IllegalStateException("Could not initialize disposable C10 Oracle test database", failure);
        }
    }

    private static void runSql(String user, String password, String filename)
            throws IOException, InterruptedException {
        String file = "/tmp/wallet-c10-db/migration/" + filename;
        String sqlplus = "sqlplus -L -s '" + user + "/" + password
                + "@//localhost:1521/FREEPDB1'";
        String command = "printf '%s\\n' "
                + "'WHENEVER OSERROR EXIT FAILURE' "
                + "'WHENEVER SQLERROR EXIT FAILURE ROLLBACK' "
                + "'SET SQLBLANKLINES ON' "
                + "'@" + file + "' "
                + "'EXIT SUCCESS'"
                + " | " + sqlplus;
        exec(command);
    }

    private static void exec(String command) throws IOException, InterruptedException {
        Container.ExecResult result = ORACLE.execInContainer("bash", "-lc", "set -eo pipefail; " + command);
        if (result.getExitCode() != 0) {
            throw new IllegalStateException("Oracle test setup command failed (code "
                    + result.getExitCode() + "):\n" + result.getStdout() + "\n" + result.getStderr());
        }
    }

    static String jdbcUrl() {
        return "jdbc:oracle:thin:@//" + ORACLE.getHost()
                + ":" + ORACLE.getOraclePort() + "/FREEPDB1";
    }
}
