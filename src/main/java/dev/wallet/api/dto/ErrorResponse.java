package dev.wallet.api.dto;

import java.time.OffsetDateTime;

public record ErrorResponse(
        String code,
        String message,
        int status,
        OffsetDateTime timestamp
) { }
