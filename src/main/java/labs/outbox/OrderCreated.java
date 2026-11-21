package labs.outbox;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;
import java.time.OffsetDateTime;
import java.util.UUID;

record OrderCreated(
        @NotNull UUID eventId,
        @NotNull UUID orderId,
        @NotBlank @Size(max = 100) String sku,
        @Positive int quantity,
        @NotNull OffsetDateTime createdAt) {
}
