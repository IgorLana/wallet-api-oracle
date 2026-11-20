package dev.wallet.api.dto;

import dev.wallet.api.model.Wallet;
import dev.wallet.api.model.WalletTransaction;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import static org.junit.jupiter.api.Assertions.*;

class MoneyPresentationTest {
    private static final OffsetDateTime TIME = OffsetDateTime.parse("2026-11-19T20:00:00Z");

    @Test
    void zeroBalanceIsRepresentedWithTwoDecimalPlaces() {
        Wallet wallet = new Wallet(1L, "Test", BigDecimal.ZERO, TIME, TIME);
        assertEquals("0.00", WalletResponse.from(wallet).balance().toPlainString());
    }

    @Test
    void statementAmountsAreRepresentedWithTwoDecimalPlaces() {
        WalletTransaction movement = new WalletTransaction(1L, 2L, "CREDIT",
                new BigDecimal("4"), new BigDecimal("4"), TIME);
        assertEquals("4.00", movement.amount().toPlainString());
        assertEquals("4.00", movement.balanceAfter().toPlainString());
    }
}
