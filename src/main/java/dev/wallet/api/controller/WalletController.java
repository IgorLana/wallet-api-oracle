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
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.Parameter;
import io.swagger.v3.oas.annotations.enums.ParameterIn;
import io.swagger.v3.oas.annotations.media.Content;
import io.swagger.v3.oas.annotations.media.ExampleObject;
import io.swagger.v3.oas.annotations.media.Schema;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import io.swagger.v3.oas.annotations.responses.ApiResponses;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import io.swagger.v3.oas.annotations.tags.Tag;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.time.OffsetDateTime;

@RestController
@RequestMapping("/wallets")
@Tag(name = "Wallets", description = "Wallet creation, balance and transaction statement")
@SecurityRequirement(name = "apiKeyAuth")
public class WalletController {
    private final WalletService service;

    public WalletController(WalletService service) {
        this.service = service;
    }

    @Operation(summary = "Create wallet",
            description = "Creates a BRL wallet with balance 0.00. holderName is optional.")
    @ApiResponses({
            @ApiResponse(responseCode = "201", description = "Wallet created",
                    content = @Content(schema = @Schema(implementation = WalletResponse.class))),
            @ApiResponse(responseCode = "400", description = "Invalid holder name",
                    content = @Content(schema = @Schema(implementation = ErrorResponse.class))),
            @ApiResponse(responseCode = "401", description = "Invalid or missing API key")
    })
    @PostMapping
    public ResponseEntity<WalletResponse> createWallet(
            @RequestBody(required = false) CreateWalletRequest request) {
        WalletResponse wallet = service.createWallet(request == null ? null : request.holderName());
        return ResponseEntity.created(URI.create("/wallets/" + wallet.id())).body(wallet);
    }

    @Operation(summary = "Get wallet", description = "Reads the wallet balance through an authorized Oracle view.")
    @ApiResponses({
            @ApiResponse(responseCode = "200", description = "Wallet found",
                    content = @Content(schema = @Schema(implementation = WalletResponse.class))),
            @ApiResponse(responseCode = "401", description = "Invalid or missing API key"),
            @ApiResponse(responseCode = "404", description = "Wallet not found",
                    content = @Content(schema = @Schema(implementation = ErrorResponse.class)))
    })
    @GetMapping("/{id}")
    public WalletResponse getWallet(@PathVariable long id) {
        return service.getWallet(id);
    }

    @Operation(summary = "Apply credit or debit",
            description = "Idempotency-Key is global. Same key and payload return the original result; "
                    + "a different payload returns 409. A rejected debit returns 422 and is persisted "
                    + "before the HTTP response, allowing subsequent retries to reproduce the rejection.")
    @ApiResponses({
            @ApiResponse(responseCode = "201", description = "Applied or replayed financial transaction",
                    content = @Content(schema = @Schema(implementation = TransactionResponse.class))),
            @ApiResponse(responseCode = "400", description = "Invalid request or operation"),
            @ApiResponse(responseCode = "401", description = "Invalid or missing API key"),
            @ApiResponse(responseCode = "404", description = "Wallet not found"),
            @ApiResponse(responseCode = "409", description = "Idempotency-Key conflict",
                    content = @Content(schema = @Schema(implementation = ErrorResponse.class),
                            examples = @ExampleObject(name = "Idempotency conflict",
                                    value = "{\"code\":\"IDEMPOTENCY_KEY_CONFLICT\",\"message\":\"Idempotency-Key conflict\",\"status\":409,\"timestamp\":\"2026-11-19T20:00:00Z\"}"))),
            @ApiResponse(responseCode = "422", description = "Insufficient funds (historical rejection)",
                    content = @Content(schema = @Schema(implementation = ErrorResponse.class),
                            examples = @ExampleObject(name = "Insufficient funds",
                                    value = "{\"code\":\"INSUFFICIENT_FUNDS\",\"message\":\"Insufficient funds\",\"status\":422,\"timestamp\":\"2026-11-19T20:00:00Z\"}"))),
            @ApiResponse(responseCode = "503", description = "Wallet row lock timeout")
    })
    @PostMapping("/{id}/transactions")
    public ResponseEntity<?> registerTransaction(
            @PathVariable long id,
            @Parameter(in = ParameterIn.HEADER, name = "Idempotency-Key", required = true,
                    description = "Client-supplied unique key, up to 100 characters; reuse only for the same logical request",
                    example = "deposit-2026-001")
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

    @Operation(summary = "Get paginated statement",
            description = "Only applied ledger movements are listed. page starts at 0, size must be 1..100. "
                    + "from is inclusive and to is exclusive. Entries are ordered newest first.")
    @ApiResponses({
            @ApiResponse(responseCode = "200", description = "Paginated financial statement",
                    content = @Content(schema = @Schema(implementation = TransactionPageResponse.class))),
            @ApiResponse(responseCode = "400", description = "Invalid pagination or date range"),
            @ApiResponse(responseCode = "401", description = "Invalid or missing API key"),
            @ApiResponse(responseCode = "404", description = "Wallet not found")
    })
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
