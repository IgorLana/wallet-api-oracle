package dev.wallet.api.controller;

import dev.wallet.api.dto.CreateTransactionRequest;
import dev.wallet.api.dto.CreateWalletRequest;
import dev.wallet.api.dto.ErrorResponse;
import dev.wallet.api.dto.TransactionPageResponse;
import dev.wallet.api.dto.TransactionResponse;
import dev.wallet.api.dto.WalletResponse;
import dev.wallet.api.model.TransactionOutcome;
import dev.wallet.api.service.WalletService;
import jakarta.validation.Valid;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.time.OffsetDateTime;

@RestController
@RequestMapping("/wallets")
public class WalletController {
    private final WalletService service;

    public WalletController(WalletService service) {
        this.service = service;
    }

    @PostMapping
    public ResponseEntity<WalletResponse> createWallet(
            @RequestBody(required = false) CreateWalletRequest request) {
        WalletResponse wallet = service.createWallet(request == null ? null : request.holderName());
        return ResponseEntity.created(URI.create("/wallets/" + wallet.id())).body(wallet);
    }

    @GetMapping("/{id}")
    public WalletResponse getWallet(@PathVariable long id) {
        return service.getWallet(id);
    }

    @PostMapping("/{id}/transactions")
    public ResponseEntity<?> registerTransaction(
            @PathVariable long id,
            @RequestHeader("Idempotency-Key") String idempotencyKey,
            @Valid @RequestBody CreateTransactionRequest request) {
        // When this call returns, its @Transactional proxy has committed successfully.
        TransactionOutcome result = service.registerTransaction(
                id, idempotencyKey, request.type(), request.amount());

        HttpHeaders headers = new HttpHeaders();
        headers.add("Idempotent-Replayed", Boolean.toString(result.replayed()));
        if ("REJECTED".equals(result.status())) {
            // Do NOT throw an unchecked exception inside the service: that rolls back
            // the rejection record whose outcome must survive future retries.
            ErrorResponse error = new ErrorResponse("INSUFFICIENT_FUNDS",
                    "Insufficient funds", HttpStatus.UNPROCESSABLE_CONTENT.value(),
                    result.completedAt());
            return ResponseEntity.status(HttpStatus.UNPROCESSABLE_CONTENT)
                    .headers(headers).body(error);
        }
        if (!"APPLIED".equals(result.status())) {
            throw new IllegalStateException("Unrecognized package result status");
        }
        return ResponseEntity.status(HttpStatus.CREATED).headers(headers)
                .body(TransactionResponse.from(result));
    }

    @GetMapping("/{id}/transactions")
    public TransactionPageResponse getTransactions(
            @PathVariable long id,
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME)
                    OffsetDateTime from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME)
                    OffsetDateTime to) {
        return service.getTransactions(id, page, size, from, to);
    }
}
