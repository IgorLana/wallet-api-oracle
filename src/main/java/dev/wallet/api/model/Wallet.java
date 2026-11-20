package dev.wallet.api.model;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

public record Wallet(
        long id,
        String holderName,
        BigDecimal balance,
        OffsetDateTime createdAt,
        OffsetDateTime updatedAt
) { }
