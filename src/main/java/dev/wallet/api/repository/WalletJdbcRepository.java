package dev.wallet.api.repository;

import dev.wallet.api.model.PagedTransactions;
import dev.wallet.api.model.TransactionOutcome;
import dev.wallet.api.model.Wallet;
import dev.wallet.api.model.WalletTransaction;
import org.springframework.jdbc.core.CallableStatementCreator;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.sql.CallableStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Types;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.Optional;

@Repository
public class WalletJdbcRepository {
    private final JdbcTemplate jdbc;

    public WalletJdbcRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** Only the package can perform writes. No INSERT/UPDATE/DELETE here. */
    public long createWallet(String holderName) {
        Long id = jdbc.execute((CallableStatementCreator) connection -> {
            CallableStatement cs = connection.prepareCall(
                    "{call WALLET_OWNER.PKG_WALLET.CREATE_WALLET(?, ?, ?, ?)}");
            cs.setString(1, holderName);
            cs.registerOutParameter(2, Types.NUMERIC);
            cs.registerOutParameter(3, Types.NUMERIC);
            cs.registerOutParameter(4, Types.TIMESTAMP_WITH_TIMEZONE);
            return cs;
        }, cs -> {
            cs.execute();
            return cs.getLong(2);
        });
        return Objects.requireNonNull(id, "Package did not return wallet ID");
    }

    public TransactionOutcome registerTransaction(
            long walletId, String idemKey, String type, BigDecimal amount) {
        TransactionOutcome outcome = jdbc.execute((CallableStatementCreator) connection -> {
            CallableStatement cs = connection.prepareCall(
                    "{call WALLET_OWNER.PKG_WALLET.REGISTER_TRANSACTION(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)}");
            cs.setLong(1, walletId);
            cs.setString(2, idemKey);
            cs.setString(3, type);
            cs.setBigDecimal(4, amount);
            cs.registerOutParameter(5, Types.NUMERIC);
            cs.registerOutParameter(6, Types.NUMERIC);
            cs.registerOutParameter(7, Types.VARCHAR);
            cs.registerOutParameter(8, Types.VARCHAR);
            cs.registerOutParameter(9, Types.TIMESTAMP_WITH_TIMEZONE);
            cs.registerOutParameter(10, Types.VARCHAR);
            return cs;
        }, cs -> {
            cs.execute();
            BigDecimal transactionId = cs.getBigDecimal(5);
            return new TransactionOutcome(
                    walletId, type, amount,
                    transactionId == null ? null : transactionId.longValueExact(),
                    cs.getBigDecimal(6),
                    cs.getString(7),
                    cs.getString(8),
                    cs.getObject(9, OffsetDateTime.class),
                    "Y".equals(cs.getString(10))
            );
        });
        return Objects.requireNonNull(outcome, "Package returned no transaction result");
    }

    /** WALLET_APP has READ on these views; it has no direct DML on tables. */
    public Optional<Wallet> findById(long walletId) {
        List<Wallet> wallets = jdbc.query(
                "SELECT id, holder_name, balance, created_at, updated_at " +
                "FROM WALLET_OWNER.V_WALLET WHERE id = ?",
                (rs, rowNum) -> new Wallet(
                        rs.getLong("id"), rs.getString("holder_name"),
                        rs.getBigDecimal("balance"),
                        rs.getObject("created_at", OffsetDateTime.class),
                        rs.getObject("updated_at", OffsetDateTime.class)),
                walletId);
        return wallets.stream().findFirst();
    }

    public PagedTransactions findTransactions(
            long walletId, OffsetDateTime from, OffsetDateTime to, int page, int size) {
        StringBuilder where = new StringBuilder(" WHERE wallet_id = ?");
        List<Object> args = new ArrayList<>();
        args.add(walletId);
        if (from != null) {
            where.append(" AND created_at >= ?");
            args.add(from);
        }
        if (to != null) {
            where.append(" AND created_at < ?"); // exclusive upper bound
            args.add(to);
        }

        Long total = jdbc.queryForObject(
                "SELECT COUNT(*) FROM WALLET_OWNER.V_WALLET_TRANSACTION" + where,
                Long.class, args.toArray());

        String sql = "SELECT id, wallet_id, transaction_type, amount, balance_after, created_at " +
                "FROM WALLET_OWNER.V_WALLET_TRANSACTION" + where +
                " ORDER BY created_at DESC, id DESC OFFSET ? ROWS FETCH NEXT ? ROWS ONLY";
        List<Object> pageArgs = new ArrayList<>(args);
        pageArgs.add((long) page * size);
        pageArgs.add(size);

        List<WalletTransaction> items = jdbc.query(sql, (rs, rowNum) -> mapTransaction(rs),
                pageArgs.toArray());
        return new PagedTransactions(items, Objects.requireNonNull(total));
    }

    private static WalletTransaction mapTransaction(ResultSet rs) throws SQLException {
        return new WalletTransaction(
                rs.getLong("id"), rs.getLong("wallet_id"),
                rs.getString("transaction_type"), rs.getBigDecimal("amount"),
                rs.getBigDecimal("balance_after"),
                rs.getObject("created_at", OffsetDateTime.class));
    }
}
