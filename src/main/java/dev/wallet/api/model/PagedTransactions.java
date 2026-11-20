package dev.wallet.api.model;

import java.util.List;

public record PagedTransactions(
        List<WalletTransaction> items,
        long totalElements
) { }
