package dev.wallet.api.exception;

import dev.wallet.api.dto.ErrorResponse;
import org.junit.jupiter.api.Test;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.UncategorizedSQLException;

import java.sql.SQLException;

import static org.junit.jupiter.api.Assertions.*;

class GlobalExceptionHandlerTest {
    private final GlobalExceptionHandler handler = new GlobalExceptionHandler();

    @Test
    void mapsOracleIdempotencyConflictToHttp409() {
        SQLException sql = new SQLException("ORA-20005", "72000", 20005);
        ResponseEntity<ErrorResponse> response = handler.onDatabaseError(
                new UncategorizedSQLException("registerTransaction", "call pkg_wallet", sql));
        assertEquals(409, response.getStatusCode().value());
        assertNotNull(response.getBody());
        assertEquals("IDEMPOTENCY_KEY_CONFLICT", response.getBody().code());
    }

    @Test
    void masksUnexpectedDatabaseErrors() {
        SQLException sql = new SQLException("sensitive internal details", "72000", 99999);
        ResponseEntity<ErrorResponse> response = handler.onDatabaseError(
                new UncategorizedSQLException("db", "internal sql", sql));
        assertEquals(500, response.getStatusCode().value());
        assertNotNull(response.getBody());
        assertEquals("DATABASE_ERROR", response.getBody().code());
        assertFalse(response.getBody().message().contains("sensitive"));
    }

    @Test
    void mapsInvalidAmountTo400() {
        assertOracleMapping(20001, 400, "INVALID_AMOUNT");
    }

    @Test
    void mapsUnknownWalletTo404() {
        assertOracleMapping(20003, 404, "WALLET_NOT_FOUND");
    }

    @Test
    void mapsLockTimeoutTo503() {
        assertOracleMapping(20006, 503, "WALLET_BUSY");
    }

    @Test
    void mapsInvalidIdempotencyKeyTo400() {
        assertOracleMapping(20007, 400, "INVALID_IDEMPOTENCY_KEY");
    }

    @Test
    void mapsInvalidHolderNameTo400() {
        assertOracleMapping(20008, 400, "INVALID_HOLDER_NAME");
    }

    @Test
    void mapsIncompleteRequestTo409() {
        assertOracleMapping(20009, 409, "INCOMPLETE_REQUEST");
    }

    private void assertOracleMapping(int oracleCode, int httpStatus, String errorCode) {
        SQLException sql = new SQLException("ORA-" + oracleCode, "72000", oracleCode);
        ResponseEntity<ErrorResponse> response = handler.onDatabaseError(
                new UncategorizedSQLException("procedure call", "call pkg_wallet", sql));
        assertEquals(httpStatus, response.getStatusCode().value());
        assertNotNull(response.getBody());
        assertEquals(errorCode, response.getBody().code());
        assertEquals(httpStatus, response.getBody().status());
    }
}
