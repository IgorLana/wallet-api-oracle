package dev.wallet.api.model;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

public record WalletTransaction(
        long id,
        long walletId,
        String type,
        BigDecimal amount,
        BigDecimal balanceAfter,
        OffsetDateTime createdAt
) {
    // Fixed-scale BRL representation in the public statement response.
    public WalletTransaction {
        amount = amount.setScale(2, java.math.RoundingMode.UNNECESSARY);
        balanceAfter = balanceAfter.setScale(2, java.math.RoundingMode.UNNECESSARY);
    }
}
