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
}
