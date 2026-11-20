package dev.wallet.api.model;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

/** Exact business result returned by PKG_WALLET.REGISTER_TRANSACTION. */
public record TransactionOutcome(
        long walletId,
        String type,
        BigDecimal amount,
        Long transactionId,
        BigDecimal balanceAfter,
        String status,
        String rejectionCode,
        OffsetDateTime completedAt,
        boolean replayed
) { }
