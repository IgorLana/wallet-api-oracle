package dev.wallet.api.controller;

import dev.wallet.api.dto.CreateTransactionRequest;
import dev.wallet.api.dto.ErrorResponse;
import dev.wallet.api.dto.TransactionResponse;
import dev.wallet.api.model.TransactionOutcome;
import dev.wallet.api.service.WalletService;
import org.junit.jupiter.api.Test;
import org.springframework.http.ResponseEntity;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class WalletControllerTest {
    private final WalletService service = mock(WalletService.class);
    private final WalletController controller = new WalletController(service);
    private static final OffsetDateTime ORIGINAL_TIME = OffsetDateTime.parse("2026-11-19T20:00:00Z");

    @Test
    void rejectedDebitBecomesHttp422WithOriginalTimestamp() {
        TransactionOutcome outcome = new TransactionOutcome(7, "DEBIT", new BigDecimal("30.00"),
                null, null, "REJECTED", "INSUFFICIENT_FUNDS", ORIGINAL_TIME, false);
        when(service.registerTransaction(7, "key-denied", "DEBIT", new BigDecimal("30.00")))
                .thenReturn(outcome);

        ResponseEntity<?> response = controller.registerTransaction(7, "key-denied",
                new CreateTransactionRequest("DEBIT", new BigDecimal("30.00")));

        assertEquals(422, response.getStatusCode().value());
        assertEquals("false", response.getHeaders().getFirst("Idempotent-Replayed"));
        assertInstanceOf(ErrorResponse.class, response.getBody());
        ErrorResponse body = (ErrorResponse) response.getBody();
        assertEquals("INSUFFICIENT_FUNDS", body.code());
        assertEquals(ORIGINAL_TIME, body.timestamp());
        verify(service).registerTransaction(7, "key-denied", "DEBIT", new BigDecimal("30.00"));
    }

    @Test
    void rejectedReplayKeepsHttp422AndReplayHeader() {
        TransactionOutcome replay = new TransactionOutcome(7, "DEBIT", new BigDecimal("30.00"),
                null, null, "REJECTED", "INSUFFICIENT_FUNDS", ORIGINAL_TIME, true);
        when(service.registerTransaction(7, "key-denied", "DEBIT", new BigDecimal("30.00")))
                .thenReturn(replay);
        ResponseEntity<?> response = controller.registerTransaction(7, "key-denied",
                new CreateTransactionRequest("DEBIT", new BigDecimal("30.00")));
        assertEquals(422, response.getStatusCode().value());
        assertEquals("true", response.getHeaders().getFirst("Idempotent-Replayed"));
        assertEquals(ORIGINAL_TIME, ((ErrorResponse) response.getBody()).timestamp());
    }

    @Test
    void appliedCreditReturns201AndTransaction() {
        TransactionOutcome applied = new TransactionOutcome(7, "CREDIT", new BigDecimal("1"),
                99L, new BigDecimal("1"), "APPLIED", null, ORIGINAL_TIME, false);
        when(service.registerTransaction(7, "key-credit", "CREDIT", BigDecimal.ONE)).thenReturn(applied);
        ResponseEntity<?> response = controller.registerTransaction(7, "key-credit",
                new CreateTransactionRequest("CREDIT", BigDecimal.ONE));
        assertEquals(201, response.getStatusCode().value());
        assertInstanceOf(TransactionResponse.class, response.getBody());
        TransactionResponse body = (TransactionResponse) response.getBody();
        assertEquals("1.00", body.amount().toPlainString());
        assertEquals("1.00", body.balanceAfter().toPlainString());
    }
}
