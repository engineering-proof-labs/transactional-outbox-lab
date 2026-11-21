package labs.outbox;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;
import java.net.URI;
import java.util.UUID;
import org.springframework.context.annotation.Profile;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@Profile("orders")
@RestController
@RequestMapping("/orders")
class OrdersController {

    private final OrderStore orders;

    OrdersController(OrderStore orders) {
        this.orders = orders;
    }

    @PostMapping
    ResponseEntity<OrderCreated> create(@Valid @RequestBody CreateOrder request) {
        OrderCreated event = orders.create(request.sku(), request.quantity());
        return ResponseEntity.created(URI.create("/orders/" + event.orderId())).body(event);
    }

    @GetMapping("/{id}")
    ResponseEntity<OrderCreated> get(@PathVariable UUID id) {
        return ResponseEntity.of(orders.find(id));
    }

    record CreateOrder(@NotBlank @Size(max = 100) String sku, @Positive int quantity) {
    }
}
