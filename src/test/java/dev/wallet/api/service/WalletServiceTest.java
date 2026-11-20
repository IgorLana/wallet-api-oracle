package dev.wallet.api.service;

import dev.wallet.api.dto.WalletResponse;
import dev.wallet.api.exception.WalletApiException;
import dev.wallet.api.model.TransactionOutcome;
import dev.wallet.api.model.Wallet;
import dev.wallet.api.repository.WalletJdbcRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class WalletServiceTest {

    @Mock
    WalletJdbcRepository repository;

    WalletService service;

    @BeforeEach
    void setup() {
        service = new WalletService(repository);
    }

    @Test
    void createsWalletAndReadsItsSavedResult() {
        OffsetDateTime timestamp = OffsetDateTime.now(ZoneOffset.UTC);
        Wallet wallet = new Wallet(42, "Ana", new BigDecimal("0.00"), timestamp, timestamp);
        when(repository.createWallet("Ana")).thenReturn(42L);
        when(repository.findById(42L)).thenReturn(Optional.of(wallet));

        WalletResponse response = service.createWallet("Ana");

        assertEquals(42L, response.id());
        assertEquals(0, response.balance().compareTo(BigDecimal.ZERO));
        verify(repository).createWallet("Ana");
        verify(repository).findById(42L);
    }

    @Test
    void missingWalletIsNotFound() {
        when(repository.findById(99L)).thenReturn(Optional.empty());

        WalletApiException ex = assertThrows(WalletApiException.class, () -> service.getWallet(99L));
        assertEquals("WALLET_NOT_FOUND", ex.code());
    }

    @Test
    void rejectsInvalidPaginationBeforeCallingRepository() {
        assertThrows(WalletApiException.class,
                () -> service.getTransactions(42L, -1, 20, null, null));
        assertThrows(WalletApiException.class,
                () -> service.getTransactions(42L, 0, 101, null, null));
        verifyNoInteractions(repository);
    }

    @Test
    void rejectedDebitIsReturnedAsDataNotThrownAsException() {
        TransactionOutcome rejected = new TransactionOutcome(
                42L, "DEBIT", new BigDecimal("50.00"), null, null,
                "REJECTED", "INSUFFICIENT_FUNDS", OffsetDateTime.now(ZoneOffset.UTC), false);
        when(repository.registerTransaction(42L, "attempt-1", "DEBIT", new BigDecimal("50.00")))
                .thenReturn(rejected);

        TransactionOutcome actual = service.registerTransaction(42L, "attempt-1",
                "DEBIT", new BigDecimal("50.00"));

        assertSame(rejected, actual);
        assertEquals("REJECTED", actual.status());
    }
}
