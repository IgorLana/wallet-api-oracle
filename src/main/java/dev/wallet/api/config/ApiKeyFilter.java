package dev.wallet.api.config;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;

@Component
public class ApiKeyFilter extends OncePerRequestFilter {
    private final byte[] expectedKey;

    public ApiKeyFilter(@Value("${wallet.api-key}") String apiKey) {
        if (apiKey.isBlank() || apiKey.equals("CHANGE_ME") || apiKey.length() < 16) {
            throw new IllegalArgumentException("WALLET_API_KEY must contain at least 16 characters");
        }
        this.expectedKey = apiKey.getBytes(StandardCharsets.UTF_8);
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getServletPath();
        return !(path.equals("/wallets") || path.startsWith("/wallets/"));
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        String supplied = request.getHeader("X-API-Key");
        byte[] actual = supplied == null ? new byte[0] : supplied.getBytes(StandardCharsets.UTF_8);
        if (!MessageDigest.isEqual(expectedKey, actual)) {
            response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
            response.setContentType("application/json");
            response.setCharacterEncoding(StandardCharsets.UTF_8.name());
            response.getWriter().write("{\"code\":\"UNAUTHORIZED\",\"message\":\"Invalid API key\","
                    + "\"status\":401,\"timestamp\":\"" + Instant.now() + "\"}");
            return;
        }
        chain.doFilter(request, response);
    }
}
