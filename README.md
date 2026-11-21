# Transactional Outbox Lab

An order can commit just before the application crashes, leaving shipping unaware of it. This lab saves the order and its `OrderCreated` event in one PostgreSQL transaction. A separate worker delivers pending events over HTTP. Shipping uses the event ID to create one shipment even when the worker sends the same event twice.

## Run the three-scene demo

Use Docker with Compose v2 and PowerShell 7. Docker builds and runs the Java 21 application. The examples use a fresh Compose project and the API listens at `127.0.0.1:8082`. Set `OUTBOX_API_PORT` and update `$api` if that port is in use.

```powershell
$env:COMPOSE_PROJECT_NAME = 'outbox-demo'
$api = 'http://127.0.0.1:8082'
docker compose build api
docker compose up -d postgres api worker
```

Choose a fresh project name if you stopped a previous demo before all events were delivered. Wait for the `Started OutboxApplication` line from `docker compose logs api` before posting an order.

### 1. Create an order while shipping is down

```powershell
$first = Invoke-RestMethod -Method Post -Uri "$api/orders" -ContentType 'application/json' `
  -Body '{"sku":"desk-lamp","quantity":1}'
Invoke-RestMethod "$api/orders/$($first.orderId)"

docker compose exec -T postgres psql -U outbox -d orders -c "
  SELECT event_id, order_id, attempt_count, delivered_at
  FROM outbox_events WHERE event_id = '$($first.eventId)';"
```

The order is readable by ID. Repeat the query until `attempt_count` is at least 1. `delivered_at` stays empty while shipping is down. The event ID in `docker compose logs worker` matches the stored row. To check persistence across an API restart, run `docker compose restart api` and read the same order again once the API starts.

### 2. Bring shipping online

```powershell
docker compose up -d shipping

docker compose exec -T postgres psql -U outbox -d orders -c "
  SELECT event_id, attempt_count, delivered_at
  FROM outbox_events WHERE event_id = '$($first.eventId)';"
docker compose exec -T postgres psql -U outbox -d shipping -c "
  SELECT id, event_id, order_id FROM shipments WHERE event_id = '$($first.eventId)';"
```

Repeat the queries as shipping starts and the next retry runs. The existing event gains a `delivered_at` timestamp and shipping has one row for that event. The worker recovers without another order request.

### 3. Crash the worker after shipping acknowledges

Stop the regular worker so the next order can only be picked up by the one-off worker. The fault switch makes the JVM halt immediately after the HTTP success response and before updating `delivered_at`.

```powershell
docker compose stop worker
$second = Invoke-RestMethod -Method Post -Uri "$api/orders" -ContentType 'application/json' `
  -Body '{"sku":"floor-lamp","quantity":2}'
docker compose run --rm -e OUTBOX_CRASH_AFTER_DELIVERY=true worker
$LASTEXITCODE
```

The one-off worker exits with code `42`. Run these queries before restarting the regular worker.

```powershell
docker compose exec -T postgres psql -U outbox -d orders -c "
  SELECT event_id, attempt_count, delivered_at
  FROM outbox_events WHERE event_id = '$($second.eventId)';"
docker compose exec -T postgres psql -U outbox -d shipping -c "
  SELECT id, event_id, order_id FROM shipments WHERE event_id = '$($second.eventId)';"
```

At the crash checkpoint, the second event has one recorded attempt and `delivered_at` is empty. Shipping already has one shipment. Restart the normal worker and look for `duplicate acknowledged` with the same event ID in the shipping logs.

```powershell
docker compose up -d worker
docker compose logs shipping
```

Repeat the two queries after the duplicate appears. The attempt count is now 2, `delivered_at` is set, and the query still returns the original shipment ID as its only row. Run `docker compose down` when finished. PostgreSQL data stays in the project’s named volume.

## Follow the code

- [`OrdersController`](src/main/java/labs/outbox/OrdersController.java) accepts `POST /orders` and reads a saved order with `GET /orders/{id}`. [`OrderStore`](src/main/java/labs/outbox/OrderStore.java) inserts both rows inside a Spring `@Transactional` method.
- [`OutboxWorker`](src/main/java/labs/outbox/OutboxWorker.java) reads due rows, sets the next eligible retry two seconds after each attempt starts, and sends the stored event snapshot. It marks the event delivered only after a 2xx response. The worker holds no database transaction open during the HTTP call.
- [`ShippingController`](src/main/java/labs/outbox/ShippingController.java) returns `204` once its database write succeeds. The unique `event_id` constraint and `ON CONFLICT DO NOTHING` make a repeat delivery safe in a single SQL statement. [`db/init.sql`](db/init.sql) creates the orders and shipping databases in the same PostgreSQL instance.

The delivery contract is at least once, assuming the worker and shipping become available again and the database volume survives. The idempotency guarantee applies to creating a shipment for a particular event ID. The lab runs one worker with serial polling and retries pending events indefinitely.

[Transactional outbox pattern in AWS Prescriptive Guidance](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/transactional-outbox.html)
