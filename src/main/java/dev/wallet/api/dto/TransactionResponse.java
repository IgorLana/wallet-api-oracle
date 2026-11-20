package dev.wallet.api.dto;

import dev.wallet.api.model.TransactionOutcome;
import java.math.BigDecimal;
import java.time.OffsetDateTime;

public record TransactionResponse(
        long id,
        long walletId,
        String type,
        BigDecimal amount,
        BigDecimal balanceAfter,
        OffsetDateTime createdAt
) {
    public static TransactionResponse from(TransactionOutcome outcome) {
        if (outcome.transactionId() == null) {
            throw new IllegalArgumentException("Cannot map rejected attempt to ledger transaction");
        }
        return new TransactionResponse(outcome.transactionId(), outcome.walletId(),
                outcome.type(), outcome.amount(), outcome.balanceAfter(), outcome.completedAt());
    }
}
