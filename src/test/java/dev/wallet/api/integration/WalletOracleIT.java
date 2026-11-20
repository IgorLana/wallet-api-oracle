package dev.wallet.api.integration;

import dev.wallet.api.dto.WalletResponse;
import dev.wallet.api.model.TransactionOutcome;
import dev.wallet.api.repository.WalletJdbcRepository;
import dev.wallet.api.service.WalletService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.dao.DataAccessException;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Duration;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Full integration tests: disposable Oracle Free + actual V1-V6 SQL + Spring HTTP server.
 * Run: ./mvnw verify  (requires Docker Desktop, 4+ GiB free RAM recommended).
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class WalletOracleIT {

    @DynamicPropertySource
    static void oracleConfiguration(DynamicPropertyRegistry registry) {
        OracleTestDatabase.start();
        registry.add("spring.datasource.url", OracleTestDatabase::jdbcUrl);
        registry.add("spring.datasource.username", () -> "WALLET_APP");
        registry.add("spring.datasource.password", () -> OracleTestDatabase.APP_PASSWORD);
        registry.add("wallet.api-key", () -> OracleTestDatabase.API_KEY);
    }

    @Autowired
    WalletService service;

    @Autowired
    WalletJdbcRepository repository;

    @Autowired
    PlatformTransactionManager transactionManager;

    @Value("${local.server.port}")
    int port;

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();

    @Test
    void creditDebitAndLedgerAuditRemainConsistentAfterCommits() throws Exception {
        long id = wallet();
        TransactionOutcome credit = move(id, key(), "CREDIT", "100.00");
        TransactionOutcome debit = move(id, key(), "DEBIT", "40.00");

        assertEquals("APPLIED", credit.status());
        assertEquals("APPLIED", debit.status());
        money("60.00", service.getWallet(id).balance());
        assertEquals(2, repository.findTransactions(id, null, null, 0, 20).totalElements());
        assertEquals(2, countAudit(id));

        try (Connection conn = auditConnection();
             PreparedStatement sql = conn.prepareStatement(
                     "SELECT old_balance,new_balance,transaction_id FROM wallet_audit.balance_audit "
                             + "WHERE wallet_id=? ORDER BY id")) {
            sql.setLong(1, id);
            try (ResultSet rs = sql.executeQuery()) {
                assertTrue(rs.next());
                money("0.00", rs.getBigDecimal(1));
                money("100.00", rs.getBigDecimal(2));
                assertEquals(credit.transactionId().longValue(), rs.getLong(3));
                assertTrue(rs.next());
                money("100.00", rs.getBigDecimal(1));
                money("60.00", rs.getBigDecimal(2));
                assertEquals(debit.transactionId().longValue(), rs.getLong(3));
                assertFalse(rs.next());
            }
        }
    }

    @Test
    void rejectedDebitRemainsRejectedAfterLaterCreditAndCommit() throws Exception {
        long id = wallet();
        String deniedKey = key();
        TransactionOutcome rejected = move(id, deniedKey, "DEBIT", "30.00");
        assertEquals("REJECTED", rejected.status());
        assertEquals("INSUFFICIENT_FUNDS", rejected.rejectionCode());
        assertNull(rejected.transactionId());
        assertEquals(0, countAudit(id));
        assertEquals(0, ledgerCount(id));

        move(id, key(), "CREDIT", "100.00");
        TransactionOutcome retry = move(id, deniedKey, "DEBIT", "30.00");
        assertEquals("REJECTED", retry.status());
        assertTrue(retry.replayed());
        assertEquals(rejected.completedAt(), retry.completedAt());
        money("100.00", service.getWallet(id).balance());
        assertEquals(1, ledgerCount(id));
        assertEquals(2, requestCount(id));
        assertEquals(1, countAudit(id));
    }

    @Test
    void repeatedAppliedRequestReturnsHistoricalResultAndNoSecondMovement() throws Exception {
        long id = wallet();
        String idem = key();
        TransactionOutcome first = move(id, idem, "CREDIT", "17.50");
        TransactionOutcome retry = move(id, idem, "CREDIT", "17.50");

        assertFalse(first.replayed());
        assertTrue(retry.replayed());
        assertEquals(first.transactionId(), retry.transactionId());
        assertEquals(first.completedAt(), retry.completedAt());
        money("17.50", retry.balanceAfter());
        money("17.50", service.getWallet(id).balance());
        assertEquals(1, ledgerCount(id));
        assertEquals(1, countAudit(id));
    }

    @Test
    void sameKeyDifferentPayloadOrWalletReturnsConflict() throws Exception {
        long firstWallet = wallet();
        long anotherWallet = wallet();
        String idem = key();
        move(firstWallet, idem, "CREDIT", "10.00");

        DataAccessException differentAmount = assertThrows(DataAccessException.class,
                () -> move(firstWallet, idem, "CREDIT", "11.00"));
        assertOracleCode(differentAmount, 20005);
        DataAccessException differentWallet = assertThrows(DataAccessException.class,
                () -> move(anotherWallet, idem, "CREDIT", "10.00"));
        assertOracleCode(differentWallet, 20005);
        money("10.00", service.getWallet(firstWallet).balance());
        money("0.00", service.getWallet(anotherWallet).balance());
    }

    @Test
    void concurrentDebitsSerializeAndNeverOverdrawWallet() throws Exception {
        long id = wallet();
        move(id, key(), "CREDIT", "50.00");

        try (ExecutorService workers = Executors.newFixedThreadPool(2)) {
            CountDownLatch ready = new CountDownLatch(2);
            CountDownLatch start = new CountDownLatch(1);
            Future<TransactionOutcome> a = workers.submit(() -> raceMove(ready, start, id, key(), "DEBIT", "30.00"));
            Future<TransactionOutcome> b = workers.submit(() -> raceMove(ready, start, id, key(), "DEBIT", "30.00"));
            assertTrue(ready.await(10, TimeUnit.SECONDS));
            start.countDown();
            TransactionOutcome one = a.get(20, TimeUnit.SECONDS);
            TransactionOutcome two = b.get(20, TimeUnit.SECONDS);
            long applied = ("APPLIED".equals(one.status()) ? 1 : 0)
                    + ("APPLIED".equals(two.status()) ? 1 : 0);
            long rejected = ("REJECTED".equals(one.status()) ? 1 : 0)
                    + ("REJECTED".equals(two.status()) ? 1 : 0);
            assertEquals(1, applied);
            assertEquals(1, rejected);
        }

        money("20.00", service.getWallet(id).balance());
        assertEquals(2, ledgerCount(id)); // initial credit + one successful debit
        assertEquals(2, countAudit(id));
    }

    @Test
    void concurrentSameKeyOnSameWalletOnlyAppliesOnce() throws Exception {
        long id = wallet();
        String idem = key();
        try (ExecutorService workers = Executors.newFixedThreadPool(2)) {
            CountDownLatch ready = new CountDownLatch(2);
            CountDownLatch start = new CountDownLatch(1);
            Future<TransactionOutcome> a = workers.submit(() -> raceMove(ready, start, id, idem, "CREDIT", "5.00"));
            Future<TransactionOutcome> b = workers.submit(() -> raceMove(ready, start, id, idem, "CREDIT", "5.00"));
            assertTrue(ready.await(10, TimeUnit.SECONDS));
            start.countDown();
            TransactionOutcome one = a.get(20, TimeUnit.SECONDS);
            TransactionOutcome two = b.get(20, TimeUnit.SECONDS);
            assertEquals(one.transactionId(), two.transactionId());
            assertNotEquals(one.replayed(), two.replayed());
        }
        money("5.00", service.getWallet(id).balance());
        assertEquals(1, ledgerCount(id));
        assertEquals(1, countAudit(id));
    }

    @Test
    void concurrentSameKeyOnDifferentWalletsHasOnlyOneWinner() throws Exception {
        long first = wallet();
        long second = wallet();
        String idem = key();
        try (ExecutorService workers = Executors.newFixedThreadPool(2)) {
            CountDownLatch ready = new CountDownLatch(2);
            CountDownLatch start = new CountDownLatch(1);
            Future<Object> a = workers.submit(() -> raceResult(ready, start, first, idem));
            Future<Object> b = workers.submit(() -> raceResult(ready, start, second, idem));
            assertTrue(ready.await(10, TimeUnit.SECONDS));
            start.countDown();
            Object one = a.get(25, TimeUnit.SECONDS);
            Object two = b.get(25, TimeUnit.SECONDS);
            assertTrue((one instanceof TransactionOutcome && two instanceof DataAccessException)
                    || (two instanceof TransactionOutcome && one instanceof DataAccessException));
            if (one instanceof DataAccessException error) assertOracleCode(error, 20005);
            if (two instanceof DataAccessException error) assertOracleCode(error, 20005);
        }
        assertEquals(1, ledgerCount(first) + ledgerCount(second));
        assertEquals(1, countAudit(first) + countAudit(second));
    }

    @Test
    void applicationAccountCannotUpdateOwnerTablesDirectly() throws Exception {
        long id = wallet();
        try (Connection app = DriverManager.getConnection(OracleTestDatabase.jdbcUrl(),
                "WALLET_APP", OracleTestDatabase.APP_PASSWORD);
             PreparedStatement sql = app.prepareStatement(
                     "UPDATE WALLET_OWNER.WALLET SET balance=999 WHERE id=?")) {
            sql.setLong(1, id);
            assertThrows(SQLException.class, sql::executeUpdate);
        }
        money("0.00", service.getWallet(id).balance());
    }

    @Test
    void applicationCannotReadAuditOrMutateOwnerTables() throws Exception {
        long id = wallet();
        try (Connection app = DriverManager.getConnection(OracleTestDatabase.jdbcUrl(),
                "WALLET_APP", OracleTestDatabase.APP_PASSWORD)) {
            assertThrows(SQLException.class, () -> {
                try (PreparedStatement sql = app.prepareStatement(
                        "SELECT COUNT(*) FROM WALLET_AUDIT.BALANCE_AUDIT")) {
                    sql.executeQuery();
                }
            });
            assertThrows(SQLException.class, () -> {
                try (PreparedStatement sql = app.prepareStatement(
                        "INSERT INTO WALLET_OWNER.WALLET (id, balance) VALUES (-1, 0)")) {
                    sql.executeUpdate();
                }
            });
            assertThrows(SQLException.class, () -> {
                try (PreparedStatement sql = app.prepareStatement(
                        "DELETE FROM WALLET_OWNER.WALLET WHERE id=?")) {
                    sql.setLong(1, id);
                    sql.executeUpdate();
                }
            });
        }
        money("0.00", service.getWallet(id).balance());
    }

    @Test
    void springMvcReturnsCorrectStatusForUnsupportedRouteAndMediaType() throws Exception {
        HttpResponse<String> wrongMethod = http("GET", "/wallets", null, null, true);
        assertEquals(405, wrongMethod.statusCode());
        assertTrue(wrongMethod.body().contains("METHOD_NOT_ALLOWED"));

        HttpResponse<String> wrongPath = http("GET", "/no-such-api-route", null, null, false);
        assertEquals(404, wrongPath.statusCode());
        assertTrue(wrongPath.body().contains("RESOURCE_NOT_FOUND"));

        HttpRequest plainText = HttpRequest.newBuilder(URI.create("http://localhost:" + port + "/wallets"))
                .header("X-API-Key", OracleTestDatabase.API_KEY)
                .header("Content-Type", "text/plain")
                .POST(HttpRequest.BodyPublishers.ofString("plain text"))
                .build();
        HttpResponse<String> wrongType = http.send(plainText, HttpResponse.BodyHandlers.ofString());
        assertEquals(415, wrongType.statusCode());
        assertTrue(wrongType.body().contains("UNSUPPORTED_MEDIA_TYPE"));
    }

    @Test
    void uncommittedOperationRollsBackLedgerWalletRequestAndAuditTogether() throws Exception {
        long[] createdWalletId = {-1L};
        new TransactionTemplate(transactionManager).execute(status -> {
            WalletResponse created = service.createWallet("Rollback scenario");
            createdWalletId[0] = created.id();
            service.registerTransaction(created.id(), key(), "CREDIT", new BigDecimal("30.00"));
            status.setRollbackOnly();
            return null;
        });

        assertTrue(repository.findById(createdWalletId[0]).isEmpty());
        assertEquals(0, ledgerCount(createdWalletId[0]));
        assertEquals(0, countAudit(createdWalletId[0]));
        assertEquals(0, requestCount(createdWalletId[0]));
    }

    @Test
    void directLedgerUpdateAndDeleteAreBothRejected() throws Exception {
        long id = wallet();
        TransactionOutcome applied = move(id, key(), "CREDIT", "9.00");
        try (Connection conn = ownerConnection()) {
            conn.setAutoCommit(false);
            try (PreparedStatement update = conn.prepareStatement(
                    "UPDATE WALLET_OWNER.WALLET_TRANSACTION SET amount=99 WHERE id=?")) {
                update.setLong(1, applied.transactionId());
                SQLException exception = assertThrows(SQLException.class, update::executeUpdate);
                assertOracleCode(exception, 20030);
            }
            try (PreparedStatement delete = conn.prepareStatement(
                    "DELETE FROM WALLET_OWNER.WALLET_TRANSACTION WHERE id=?")) {
                delete.setLong(1, applied.transactionId());
                SQLException exception = assertThrows(SQLException.class, delete::executeUpdate);
                assertOracleCode(exception, 20030);
            }
            conn.rollback();
        }
        money("9.00", service.getWallet(id).balance());
        assertEquals(1, ledgerCount(id));
        assertEquals(1, countAudit(id));
    }

    @Test
    void ownerLockTimeoutReturnsWalletBusyError() throws Exception {
        long id = wallet();
        try (Connection lockHolder = ownerConnection()) {
            lockHolder.setAutoCommit(false);
            try (PreparedStatement sql = lockHolder.prepareStatement(
                    "SELECT balance FROM WALLET_OWNER.WALLET WHERE id=? FOR UPDATE")) {
                sql.setLong(1, id);
                try (ResultSet rs = sql.executeQuery()) {
                    assertTrue(rs.next());
                }
            }
            try (ExecutorService workers = Executors.newSingleThreadExecutor()) {
                Future<Throwable> blocked = workers.submit(() -> {
                    try {
                        move(id, key(), "CREDIT", "1.00");
                        return null;
                    } catch (Throwable error) {
                        return error;
                    }
                });
                Throwable thrown = blocked.get(15, TimeUnit.SECONDS);
                assertNotNull(thrown, "Expected the second connection to time out after WAIT 5");
                assertOracleCode(thrown, 20006);
            } finally {
                lockHolder.rollback();
            }
        }
        money("0.00", service.getWallet(id).balance());
    }

    @Test
    void apiRespondsWithAuthErrorsAndPersistsHttp422BeforeReplying() throws Exception {
        HttpResponse<String> unauthorized = http("GET", "/wallets/1", null, null, false);
        assertEquals(401, unauthorized.statusCode());

        HttpResponse<String> create = http("POST", "/wallets", "{\"holderName\":\"C10 HTTP\"}", null, true);
        assertEquals(201, create.statusCode());
        long id = parseId(create.body());
        String failedKey = key();
        HttpResponse<String> denied = http("POST", "/wallets/" + id + "/transactions",
                "{\"type\":\"DEBIT\",\"amount\":100}", failedKey, true);
        assertEquals(422, denied.statusCode());
        assertTrue(denied.body().contains("INSUFFICIENT_FUNDS"));

        HttpResponse<String> invalidScale = http("POST", "/wallets/" + id + "/transactions",
                "{\"type\":\"CREDIT\",\"amount\":1.001}", key(), true);
        assertEquals(400, invalidScale.statusCode());

        HttpResponse<String> credit = http("POST", "/wallets/" + id + "/transactions",
                "{\"type\":\"CREDIT\",\"amount\":200}", key(), true);
        assertEquals(201, credit.statusCode());

        HttpResponse<String> retry = http("POST", "/wallets/" + id + "/transactions",
                "{\"type\":\"DEBIT\",\"amount\":100}", failedKey, true);
        assertEquals(422, retry.statusCode());
        assertEquals("true", retry.headers().firstValue("Idempotent-Replayed").orElse(""));
        assertEquals(denied.body(), retry.body()); // same historical business result

        HttpResponse<String> conflict = http("POST", "/wallets/" + id + "/transactions",
                "{\"type\":\"DEBIT\",\"amount\":99}", failedKey, true);
        assertEquals(409, conflict.statusCode());
        money("200.00", service.getWallet(id).balance());
        assertEquals(1, ledgerCount(id));
    }

    private long wallet() {
        return service.createWallet("C10 isolated wallet").id();
    }

    private TransactionOutcome move(long id, String idempotencyKey, String type, String value) {
        return service.registerTransaction(id, idempotencyKey, type, new BigDecimal(value));
    }

    private TransactionOutcome raceMove(CountDownLatch ready, CountDownLatch start,
                                        long id, String idem, String type, String value) throws Exception {
        ready.countDown();
        if (!start.await(10, TimeUnit.SECONDS)) throw new IllegalStateException("Start barrier timed out");
        return move(id, idem, type, value);
    }

    private Object raceResult(CountDownLatch ready, CountDownLatch start,
                              long walletId, String idem) throws Exception {
        try {
            return raceMove(ready, start, walletId, idem, "CREDIT", "9.00");
        } catch (DataAccessException conflict) {
            return conflict;
        }
    }

    private static String key() {
        return "c10-" + UUID.randomUUID();
    }

    private static void money(String expected, BigDecimal actual) {
        assertNotNull(actual);
        assertEquals(0, new BigDecimal(expected).compareTo(actual));
    }

    private Connection ownerConnection() throws SQLException {
        return DriverManager.getConnection(OracleTestDatabase.jdbcUrl(),
                "WALLET_OWNER", OracleTestDatabase.OWNER_PASSWORD);
    }

    private Connection auditConnection() throws SQLException {
        return DriverManager.getConnection(OracleTestDatabase.jdbcUrl(),
                "WALLET_AUDIT", OracleTestDatabase.AUDIT_PASSWORD);
    }

    private long ledgerCount(long walletId) throws Exception {
        return count(ownerConnection(),
                "SELECT COUNT(*) FROM WALLET_OWNER.WALLET_TRANSACTION WHERE wallet_id=?", walletId);
    }

    private long requestCount(long walletId) throws Exception {
        return count(ownerConnection(),
                "SELECT COUNT(*) FROM WALLET_OWNER.WALLET_OPERATION_REQUEST WHERE wallet_id=?", walletId);
    }

    private long countAudit(long walletId) throws Exception {
        return count(auditConnection(),
                "SELECT COUNT(*) FROM WALLET_AUDIT.BALANCE_AUDIT WHERE wallet_id=?", walletId);
    }

    private static long count(Connection connection, String query, long walletId) throws Exception {
        try (connection; PreparedStatement sql = connection.prepareStatement(query)) {
            sql.setLong(1, walletId);
            try (ResultSet rows = sql.executeQuery()) {
                assertTrue(rows.next());
                return rows.getLong(1);
            }
        }
    }

    private static void assertOracleCode(Throwable error, int expected) {
        for (Throwable current = error; current != null; current = current.getCause()) {
            if (current instanceof SQLException sql && sql.getErrorCode() == expected) return;
            if (current.getMessage() != null && current.getMessage().contains("ORA-" + expected)) return;
        }
        fail("Expected Oracle error ORA-" + expected + ", got " + error);
    }

    private HttpResponse<String> http(String method, String path, String json,
                                      String idemKey, boolean authenticated) throws Exception {
        HttpRequest.Builder request = HttpRequest.newBuilder(
                        URI.create("http://localhost:" + port + path))
                .timeout(Duration.ofSeconds(20));
        if (authenticated) request.header("X-API-Key", OracleTestDatabase.API_KEY);
        if (idemKey != null) request.header("Idempotency-Key", idemKey);
        if (json == null) {
            request.method(method, HttpRequest.BodyPublishers.noBody());
        } else {
            request.header("Content-Type", "application/json");
            request.method(method, HttpRequest.BodyPublishers.ofString(json, StandardCharsets.UTF_8));
        }
        return http.send(request.build(), HttpResponse.BodyHandlers.ofString());
    }

    private static long parseId(String json) {
        Matcher matcher = Pattern.compile("\\\"id\\\"\\s*:\\s*(\\d+)").matcher(json);
        assertTrue(matcher.find(), "Response missing wallet ID: " + json);
        return Long.parseLong(matcher.group(1));
    }
}
