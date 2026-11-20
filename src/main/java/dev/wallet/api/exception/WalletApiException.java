package dev.wallet.api.exception;

import org.springframework.http.HttpStatus;

public class WalletApiException extends RuntimeException {
    private final HttpStatus status;
    private final String code;

    public WalletApiException(HttpStatus status, String code, String message) {
        super(message);
        this.status = status;
        this.code = code;
    }

    public HttpStatus status() { return status; }
    public String code() { return code; }
}
