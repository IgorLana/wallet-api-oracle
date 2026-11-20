package dev.wallet.api.config;

import io.swagger.v3.oas.annotations.OpenAPIDefinition;
import io.swagger.v3.oas.annotations.enums.SecuritySchemeIn;
import io.swagger.v3.oas.annotations.enums.SecuritySchemeType;
import io.swagger.v3.oas.annotations.info.Info;
import io.swagger.v3.oas.annotations.security.SecurityScheme;
import org.springframework.context.annotation.Configuration;

/** The API contract is generated from Spring MVC handlers and annotations. */
@Configuration
@OpenAPIDefinition(info = @Info(
        title = "Wallet API",
        version = "1.0.0",
        description = "BRL digital wallet backed by Oracle PL/SQL. "
                + "Writes go through WALLET_OWNER.PKG_WALLET; reads use granted views. "
                + "Financial consistency, idempotency and audit are enforced in Oracle."
))
@SecurityScheme(
        name = "apiKeyAuth",
        type = SecuritySchemeType.APIKEY,
        in = SecuritySchemeIn.HEADER,
        paramName = "X-API-Key",
        description = "System-to-system API key. Configure WALLET_API_KEY on the server."
)
public class OpenApiConfig {
}
