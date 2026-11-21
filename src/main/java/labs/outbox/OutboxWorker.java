package labs.outbox;

import java.net.http.HttpClient;
import java.time.Duration;
import java.util.Optional;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.MediaType;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

@Profile("worker")
@EnableScheduling
@Component
class OutboxWorker {

    private static final Logger log = LoggerFactory.getLogger(OutboxWorker.class);

    private final JdbcClient jdbc;
    private final RestClient shipping;
    private final boolean crashAfterDelivery;

    OutboxWorker(JdbcClient jdbc, @Value("${SHIPPING_URL}") String shippingUrl,
                 @Value("${OUTBOX_CRASH_AFTER_DELIVERY:false}") boolean crashAfterDelivery) {
        this.jdbc = jdbc;
        this.crashAfterDelivery = crashAfterDelivery;

        HttpClient httpClient = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build();
        var requestFactory = new JdkClientHttpRequestFactory(httpClient);
        requestFactory.setReadTimeout(Duration.ofSeconds(3));
        this.shipping = RestClient.builder().baseUrl(shippingUrl).requestFactory(requestFactory).build();
    }

    @Scheduled(fixedDelay = 500)
    void poll() {
        Optional<OrderCreated> pending = jdbc.sql("""
                SELECT event_id, order_id, sku, quantity, created_at
                FROM outbox_events
                WHERE delivered_at IS NULL AND next_attempt_at <= CURRENT_TIMESTAMP
                ORDER BY next_attempt_at, created_at, event_id
                LIMIT 1
                """).query(OrderCreated.class).optional();
        pending.ifPresent(this::deliver);
    }

    private void deliver(OrderCreated event) {
        UUID eventId = event.eventId();
        // Persist the attempt before HTTP so a crash leaves both evidence and a retryable row.
        long attempt = jdbc.sql("""
                UPDATE outbox_events
                SET attempt_count = attempt_count + 1,
                    next_attempt_at = CURRENT_TIMESTAMP + INTERVAL '2 seconds'
                WHERE event_id = ?
                RETURNING attempt_count
                """).param(eventId).query(Long.class).single();

        HttpStatusCode status;
        try {
            status = shipping.post().uri("/events/order-created")
                    .contentType(MediaType.APPLICATION_JSON).body(event)
                    .exchange((request, response) -> response.getStatusCode());
        } catch (RestClientException failure) {
            log.warn("OrderCreated eventId={} attempt={} delivery failed: {}",
                    eventId, attempt, failure.getMostSpecificCause().toString());
            return;
        }
        if (!status.is2xxSuccessful()) {
            log.warn("OrderCreated eventId={} attempt={} delivery returned HTTP {}", eventId, attempt, status.value());
            return;
        }

        if (crashAfterDelivery) {
            log.warn("OrderCreated eventId={} attempt={} acknowledged; halting before outbox update", eventId, attempt);
            Runtime.getRuntime().halt(42);
        }

        jdbc.sql("UPDATE outbox_events SET delivered_at = CURRENT_TIMESTAMP WHERE event_id = ?")
                .param(eventId).update();
        log.info("OrderCreated eventId={} attempt={} marked delivered", eventId, attempt);
    }
}
