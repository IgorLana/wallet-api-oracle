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
) { }
