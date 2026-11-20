package dev.wallet.api.service;

import dev.wallet.api.dto.TransactionPageResponse;
import dev.wallet.api.dto.WalletResponse;
import dev.wallet.api.exception.WalletApiException;
import dev.wallet.api.model.PagedTransactions;
import dev.wallet.api.model.TransactionOutcome;
import dev.wallet.api.repository.WalletJdbcRepository;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

@Service
public class WalletService {
    private final WalletJdbcRepository repository;

    public WalletService(WalletJdbcRepository repository) {
        this.repository = repository;
    }

    @Transactional
    public WalletResponse createWallet(String holderName) {
        long id = repository.createWallet(holderName);
        return repository.findById(id)
                .map(WalletResponse::from)
                .orElseThrow(() -> new IllegalStateException("Created wallet not found"));
    }

    @Transactional(readOnly = true)
    public WalletResponse getWallet(long id) {
        return repository.findById(id)
                .map(WalletResponse::from)
                .orElseThrow(() -> new WalletApiException(
                        HttpStatus.NOT_FOUND, "WALLET_NOT_FOUND", "Wallet not found"));
    }

    /**
     * IMPORTANT: rejected debit is a DATA result, not an exception here.
     * @Transactional must commit the REJECTED row before the HTTP layer sends 422.
     */
    @Transactional
    public TransactionOutcome registerTransaction(
            long walletId, String idempotencyKey, String type, BigDecimal amount) {
        return repository.registerTransaction(walletId, idempotencyKey, type, amount);
    }

    @Transactional(readOnly = true)
    public TransactionPageResponse getTransactions(
            long walletId, int page, int size, OffsetDateTime from, OffsetDateTime to) {
        if (page < 0 || size < 1 || size > 100) {
            throw new WalletApiException(HttpStatus.BAD_REQUEST,
                    "INVALID_PAGINATION", "page must be >= 0 and size between 1 and 100");
        }
        if (from != null && to != null && !from.isBefore(to)) {
            throw new WalletApiException(HttpStatus.BAD_REQUEST,
                    "INVALID_DATE_RANGE", "from must be earlier than to");
        }
        // Return 404 for unknown wallets instead of a misleading empty statement.
        getWallet(walletId);

        PagedTransactions result = repository.findTransactions(walletId, from, to, page, size);
        long totalPages = result.totalElements() / size +
                (result.totalElements() % size == 0 ? 0 : 1);
        return new TransactionPageResponse(result.items(), page, size,
                result.totalElements(), totalPages);
    }
}
