package labs.outbox;

import jakarta.validation.Valid;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@Profile("shipping")
@RestController
class ShippingController {

    private static final Logger log = LoggerFactory.getLogger(ShippingController.class);

    private final JdbcClient jdbc;

    ShippingController(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @PostMapping("/events/order-created")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    void receive(@Valid @RequestBody OrderCreated event) {
        int inserted = jdbc.sql("""
                INSERT INTO shipments (id, event_id, order_id, sku, quantity)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (event_id) DO NOTHING
                """).params(UUID.randomUUID(), event.eventId(), event.orderId(), event.sku(), event.quantity()).update();

        if (inserted == 1) {
            log.info("OrderCreated eventId={} shipment created", event.eventId());
        } else {
            log.info("OrderCreated eventId={} duplicate acknowledged", event.eventId());
        }
    }
}
