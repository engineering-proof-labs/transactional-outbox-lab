package labs.outbox;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.temporal.ChronoUnit;
import java.util.Optional;
import java.util.UUID;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Profile("orders")
@Service
class OrderStore {

    private final JdbcClient jdbc;

    OrderStore(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @Transactional
    public OrderCreated create(String sku, int quantity) {
        UUID orderId = UUID.randomUUID();
        UUID eventId = UUID.randomUUID();
        OffsetDateTime createdAt = OffsetDateTime.now(ZoneOffset.UTC).truncatedTo(ChronoUnit.MICROS);

        jdbc.sql("""
                INSERT INTO orders (id, sku, quantity, created_at)
                VALUES (?, ?, ?, ?)
                """).params(orderId, sku, quantity, createdAt).update();
        jdbc.sql("""
                INSERT INTO outbox_events (event_id, order_id, sku, quantity, created_at)
                VALUES (?, ?, ?, ?, ?)
                """).params(eventId, orderId, sku, quantity, createdAt).update();

        return new OrderCreated(eventId, orderId, sku, quantity, createdAt);
    }

    Optional<OrderCreated> find(UUID orderId) {
        return jdbc.sql("""
                SELECT e.event_id, o.id AS order_id, o.sku, o.quantity, o.created_at
                FROM orders o JOIN outbox_events e ON e.order_id = o.id
                WHERE o.id = ?
                """).param(orderId).query(OrderCreated.class).optional();
    }
}
