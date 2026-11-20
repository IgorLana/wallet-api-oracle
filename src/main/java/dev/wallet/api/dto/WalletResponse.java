package dev.wallet.api.dto;

import dev.wallet.api.model.Wallet;
import java.math.BigDecimal;
import java.time.OffsetDateTime;

public record WalletResponse(
        long id,
        String holderName,
        BigDecimal balance,
        OffsetDateTime createdAt,
        OffsetDateTime updatedAt
) {
    public static WalletResponse from(Wallet wallet) {
        return new WalletResponse(wallet.id(), wallet.holderName(), wallet.balance(),
                wallet.createdAt(), wallet.updatedAt());
    }
}
