package dev.wallet.api;

import dev.wallet.api.config.ApiKeyFilter;
import jakarta.servlet.http.HttpServletRequest;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import java.util.concurrent.atomic.AtomicBoolean;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Fast tests: no Oracle and no Spring application context.
 * The real Spring context is started by WalletOracleIT against Testcontainers.
 */
class WalletApiApplicationTests {

    @Test
    void apiKeyFilterRejectsMissingKey() throws Exception {
        ApiKeyFilter filter = new ApiKeyFilter("C10-Test-ApiKey-12345678");
        MockHttpServletRequest request = request("/wallets");
        MockHttpServletResponse response = new MockHttpServletResponse();
        AtomicBoolean called = new AtomicBoolean(false);

        filter.doFilter(request, response, (req, res) -> called.set(true));

        assertEquals(401, response.getStatus());
        assertTrue(response.getContentAsString().contains("UNAUTHORIZED"));
        assertFalse(called.get());
    }

    @Test
    void apiKeyFilterAcceptsCorrectKey() throws Exception {
        ApiKeyFilter filter = new ApiKeyFilter("C10-Test-ApiKey-12345678");
        MockHttpServletRequest request = request("/wallets/42");
        request.addHeader("X-API-Key", "C10-Test-ApiKey-12345678");
        MockHttpServletResponse response = new MockHttpServletResponse();
        AtomicBoolean called = new AtomicBoolean(false);

        filter.doFilter(request, response, (req, res) -> called.set(true));

        assertTrue(called.get());
        assertEquals(200, response.getStatus());
    }

    @Test
    void apiKeyFilterRejectsShortConfiguredSecret() {
        assertThrows(IllegalArgumentException.class, () -> new ApiKeyFilter("short"));
    }

    private static MockHttpServletRequest request(String path) {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setMethod("GET");
        request.setRequestURI(path);
        request.setServletPath(path);
        return request;
    }
}
