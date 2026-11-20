package dev.wallet.api.dto;

import dev.wallet.api.model.WalletTransaction;
import java.util.List;

public record TransactionPageResponse(
        List<WalletTransaction> content,
        int page,
        int size,
        long totalElements,
        long totalPages
) { }
