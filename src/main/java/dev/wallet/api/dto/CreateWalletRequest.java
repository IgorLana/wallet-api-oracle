package dev.wallet.api.dto;

/** holderName is optional; PL/SQL enforces the authoritative length/blank rules. */
public record CreateWalletRequest(String holderName) { }
