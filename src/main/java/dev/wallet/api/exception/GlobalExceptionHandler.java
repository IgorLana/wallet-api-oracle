package dev.wallet.api.exception;

import dev.wallet.api.dto.ErrorResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.MissingRequestHeaderException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.HttpMediaTypeNotSupportedException;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.servlet.resource.NoResourceFoundException;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;

import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;

@RestControllerAdvice
public class GlobalExceptionHandler {
    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(WalletApiException.class)
    public ResponseEntity<ErrorResponse> onDomainError(WalletApiException ex) {
        return error(ex.status(), ex.code(), ex.getMessage());
    }

    @ExceptionHandler(DataAccessException.class)
    public ResponseEntity<ErrorResponse> onDatabaseError(DataAccessException ex) {
        SQLException sql = firstSqlException(ex);
        int oracleCode = sql == null ? 0 : Math.abs(sql.getErrorCode());
        // Oracle RAISE_APPLICATION_ERROR(-200xx) normally appears as ORA-200xx.
        return switch (oracleCode) {
            case 20001 -> error(HttpStatus.BAD_REQUEST, "INVALID_AMOUNT", "Invalid amount");
            case 20002 -> error(HttpStatus.BAD_REQUEST, "INVALID_TRANSACTION_TYPE", "Invalid transaction type");
            case 20003 -> error(HttpStatus.NOT_FOUND, "WALLET_NOT_FOUND", "Wallet not found");
            case 20004 -> error(HttpStatus.UNPROCESSABLE_CONTENT, "INSUFFICIENT_FUNDS", "Insufficient funds");
            case 20005 -> error(HttpStatus.CONFLICT, "IDEMPOTENCY_KEY_CONFLICT", "Idempotency-Key conflict");
            case 20006 -> error(HttpStatus.SERVICE_UNAVAILABLE, "WALLET_BUSY", "Wallet is busy; retry later");
            case 20007 -> error(HttpStatus.BAD_REQUEST, "INVALID_IDEMPOTENCY_KEY", "Invalid Idempotency-Key");
            case 20008 -> error(HttpStatus.BAD_REQUEST, "INVALID_HOLDER_NAME", "Invalid holder name");
            case 20009 -> error(HttpStatus.CONFLICT, "INCOMPLETE_REQUEST", "Request is not finalized");
            default -> {
                log.error("Unexpected Oracle/JDBC failure; Oracle error code={}", oracleCode, ex);
                yield error(HttpStatus.INTERNAL_SERVER_ERROR, "DATABASE_ERROR", "Database operation failed");
            }
        };
    }

    @ExceptionHandler({MethodArgumentNotValidException.class,
            MethodArgumentTypeMismatchException.class,
            MissingRequestHeaderException.class,
            HttpMessageNotReadableException.class})
    public ResponseEntity<ErrorResponse> onInvalidHttpRequest(Exception ex) {
        return error(HttpStatus.BAD_REQUEST, "INVALID_REQUEST", "Invalid request body or parameters");
    }

    // Spring MVC client errors must not be converted to INTERNAL_ERROR by the fallback.
    @ExceptionHandler(HttpRequestMethodNotSupportedException.class)
    public ResponseEntity<ErrorResponse> onUnsupportedMethod(HttpRequestMethodNotSupportedException ex) {
        return error(HttpStatus.METHOD_NOT_ALLOWED, "METHOD_NOT_ALLOWED", "HTTP method not supported");
    }

    @ExceptionHandler(HttpMediaTypeNotSupportedException.class)
    public ResponseEntity<ErrorResponse> onUnsupportedMediaType(HttpMediaTypeNotSupportedException ex) {
        return error(HttpStatus.UNSUPPORTED_MEDIA_TYPE, "UNSUPPORTED_MEDIA_TYPE", "Content type not supported");
    }

    @ExceptionHandler(NoResourceFoundException.class)
    public ResponseEntity<ErrorResponse> onNoResource(NoResourceFoundException ex) {
        return error(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "Resource not found");
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ErrorResponse> onUnexpectedError(Exception ex) {
        log.error("Unhandled API failure", ex);
        return error(HttpStatus.INTERNAL_SERVER_ERROR, "INTERNAL_ERROR", "Unexpected server error");
    }

    private static SQLException firstSqlException(Throwable error) {
        for (Throwable current = error; current != null; current = current.getCause()) {
            if (current instanceof SQLException sql) {
                return sql;
            }
        }
        return null;
    }

    private static ResponseEntity<ErrorResponse> error(HttpStatus status, String code, String message) {
        return ResponseEntity.status(status)
                .body(new ErrorResponse(code, message, status.value(), OffsetDateTime.now(ZoneOffset.UTC)));
    }
}
