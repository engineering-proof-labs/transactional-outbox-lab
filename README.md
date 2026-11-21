# Transactional Outbox Lab

An order can commit just before the application crashes, leaving shipping unaware of it. This lab saves the order and its `OrderCreated` event in one PostgreSQL transaction. A separate worker delivers pending events over HTTP. Shipping uses the event ID to create one shipment even when the worker sends the same event twice.

## Verify the failure scenarios

From the repository root, with Docker, Compose v2, and PowerShell 7 available, run:

```powershell
pwsh -NoProfile -File ./scripts/verify.ps1
```

The [acceptance script](scripts/verify.ps1) builds the Java 21 image, starts a temporary Compose project, sends real HTTP requests, and checks both PostgreSQL databases. It prints the IDs and counts it observes, exits with an error if an assertion fails, and cleans up its own containers and volume. The API and shipping ports are allocated dynamically for this run.

| Check | Expected evidence |
| --- | --- |
| `PASS 1 Rollback` | PostgreSQL rejects the outbox insert. HTTP returns `500` and the probe SKU has zero order rows and zero event rows. |
| `PASS 2 Retry` | While shipping is down, the order exists, its event is pending, and there are zero shipments. After shipping starts, the same event is delivered. One order and one shipment exist. |
| `PASS 3 Crash and replay` | The fault worker exits `42` after shipping commits. The event is still pending after attempt one. Attempt two acknowledges the same event, marks it delivered, and leaves the original shipment ID as the only result. |
| `PASS Concurrent delivery` | Eight concurrent HTTP requests for a fresh event ID all return `204` and produce one shipment. |
| `PASS Order API` | A fractional quantity returns `400` with zero writes. A saved order stays readable after its delivered outbox row is removed. |

## Run the demo manually

Use an unused Compose project name for a clean run. The API listens at `127.0.0.1:8082`. If that port is in use, set `OUTBOX_API_PORT` and update `$api`.

```powershell
$env:COMPOSE_PROJECT_NAME = 'outbox-demo'
$api = 'http://127.0.0.1:8082'
docker compose build api
docker compose up -d postgres api
```

Wait for `Started OutboxApplication` in `docker compose logs api` before sending requests.

### 1. Roll back a partial write

Add a temporary constraint that rejects one SKU in the outbox table. The API inserts the order first, then PostgreSQL rejects the event insert in the same transaction.

```powershell
docker compose exec -T postgres psql -U outbox -d orders -c "
  ALTER TABLE outbox_events ADD CONSTRAINT demo_rollback_sku CHECK (sku <> 'rollback-probe');"
try {
  (Invoke-WebRequest -Method Post -Uri "$api/orders" -ContentType 'application/json' `
    -Body '{"sku":"rollback-probe","quantity":1}' -SkipHttpErrorCheck).StatusCode
  docker compose exec -T postgres psql -U outbox -d orders -c "
    SELECT (SELECT count(*) FROM orders WHERE sku = 'rollback-probe') AS orders,
           (SELECT count(*) FROM outbox_events WHERE sku = 'rollback-probe') AS events;"
} finally {
  docker compose exec -T postgres psql -U outbox -d orders -c 'ALTER TABLE outbox_events DROP CONSTRAINT demo_rollback_sku;'
}
```

Expect HTTP `500` and `0` in both columns. The named constraint in `docker compose logs api` identifies the failed outbox write.

### 2. Recover a pending event when shipping starts

```powershell
docker compose up -d worker
$first = Invoke-RestMethod -Method Post -Uri "$api/orders" -ContentType 'application/json' `
  -Body '{"sku":"desk-lamp","quantity":1}'
Invoke-RestMethod "$api/orders/$($first.orderId)"

function Show-Delivery([guid]$EventId) {
  docker compose exec -T postgres psql -U outbox -d orders -c "
    SELECT event_id, order_id, attempt_count, delivered_at FROM outbox_events WHERE event_id = '$EventId';"
  docker compose exec -T postgres psql -U outbox -d shipping -c "
    SELECT id, event_id, order_id FROM shipments WHERE event_id = '$EventId';"
}
Show-Delivery $first.eventId
```

The order is readable by ID. Wait for a failed attempt for `$first.eventId` in `docker compose logs worker`. `delivered_at` stays empty and the shipping query returns zero rows. Start shipping and inspect the same event again.

```powershell
docker compose up -d shipping
Show-Delivery $first.eventId
```

Repeat `Show-Delivery` as shipping starts and the next retry runs. The existing event gains a `delivered_at` timestamp and the shipment points to the original order. The worker needed no new order request.

### 3. Crash the worker after shipping acknowledges

Stop the regular worker so the next order can only be picked up by the one-off worker. The fault switch makes the JVM halt immediately after the HTTP success response and before updating `delivered_at`.

```powershell
docker compose stop worker
$second = Invoke-RestMethod -Method Post -Uri "$api/orders" -ContentType 'application/json' `
  -Body '{"sku":"floor-lamp","quantity":2}'
docker compose run --rm -e OUTBOX_CRASH_AFTER_DELIVERY=true worker
$LASTEXITCODE
Show-Delivery $second.eventId
```

The one-off worker exits `42`. Before restarting, confirm the second event has one attempt, `delivered_at` is empty, and the shipping query returns one shipment. Restart the normal worker and look for `duplicate acknowledged` with the same event ID in the shipping logs.

```powershell
docker compose up -d worker
docker compose logs shipping
Show-Delivery $second.eventId
```

Repeat `Show-Delivery` after the duplicate appears. The attempt count is now `2`, `delivered_at` is set, and the shipping query still returns the original shipment ID as its only row.

### Clean up

Run `docker compose down` to stop the manual demo and keep its PostgreSQL data. Run `docker compose down --volumes` to remove the demo's data too.

## Follow the code

- [`OrdersController`](src/main/java/labs/outbox/OrdersController.java) accepts `POST /orders` and reads a saved order with `GET /orders/{id}`. [`OrderStore`](src/main/java/labs/outbox/OrderStore.java) inserts both rows inside a Spring `@Transactional` method. The order stays readable if its outbox row is later removed. In that case `GET` returns a null `eventId`.
- [`OutboxWorker`](src/main/java/labs/outbox/OutboxWorker.java) reads due rows, sets the next eligible retry two seconds after each attempt starts, and sends the stored event snapshot. It marks the event delivered only after a 2xx response. The worker holds no database transaction open during the HTTP call.
- [`ShippingController`](src/main/java/labs/outbox/ShippingController.java) returns `204` once its database write succeeds. The unique `event_id` constraint and `ON CONFLICT DO NOTHING` make a repeat delivery safe in a single SQL statement. [`db/init.sql`](db/init.sql) creates the orders and shipping databases in the same PostgreSQL instance.

The delivery contract is at least once, assuming the worker and shipping become available again and the database volume survives. A lost HTTP response or a crash after shipping commits and before the worker sets `delivered_at` can cause the same event to arrive again. The shipment row is the deduplication record, so the same `event_id` cannot produce a second shipment. Each `POST /orders` creates a new order and a new event ID. The lab runs one worker with serial polling and retries pending events indefinitely.

[Transactional outbox pattern in AWS Prescriptive Guidance](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/transactional-outbox.html)
