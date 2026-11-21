CREATE TABLE orders (
    id uuid PRIMARY KEY,
    sku text NOT NULL CHECK (length(sku) BETWEEN 1 AND 100),
    quantity integer NOT NULL CHECK (quantity > 0),
    created_at timestamptz NOT NULL
);

-- The outbox stores a snapshot of the single event type handled by the lab.
CREATE TABLE outbox_events (
    event_id uuid PRIMARY KEY,
    order_id uuid NOT NULL UNIQUE REFERENCES orders (id),
    sku text NOT NULL CHECK (length(sku) BETWEEN 1 AND 100),
    quantity integer NOT NULL CHECK (quantity > 0),
    created_at timestamptz NOT NULL,
    attempt_count bigint NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    delivered_at timestamptz
);

CREATE INDEX outbox_pending ON outbox_events (next_attempt_at, created_at, event_id)
    WHERE delivered_at IS NULL;

CREATE DATABASE shipping;
\connect shipping

CREATE TABLE shipments (
    id uuid PRIMARY KEY,
    event_id uuid NOT NULL UNIQUE,
    order_id uuid NOT NULL,
    sku text NOT NULL CHECK (length(sku) BETWEEN 1 AND 100),
    quantity integer NOT NULL CHECK (quantity > 0),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
