# PRD: Kafka Payment Pipeline

**Reference lesson**: `/home/aleks/w-study/kafka/lessons/0005-system-design.html`
**Location in repo**: `kafka/` (new top-level directory)

---

## Problem / Motivation

Study project to learn Kafka through a realistic payment-processing pipeline — the canonical system design interview problem. Goal: hands-on understanding of topics, partitions, consumer groups, producer guarantees, the dual-write problem, and the Outbox pattern.

---

## Goals

- Implement the full pipeline from the lesson end-to-end
- Visualize event flow in a live dashboard (submit payment → watch it propagate)
- Demonstrate the dual-write bug and the Outbox fix interactively via a chaos toggle
- Self-contained: starts with one `docker compose up` from `kafka/`

## Non-Goals

- Production-grade auth / payment processing
- Integration with existing `backend/nodejs/` or `front/react/`
- Kafka Streams / ksqlDB
- Schema registry / Avro (plain JSON messages)

---

## Architecture

```
kafka/
├── docker-compose.yml          # Kafka (3 brokers + ZooKeeper), MySQL, all services, frontend
├── payment-service/            # Express API: POST /payments, GET /events (SSE), GET /payments/:id
├── outbox-worker/              # Polls outbox table → publishes to Kafka
├── fraud-service/              # Consumer group:fraud — 200ms simulated ML delay
├── notifier/                   # Consumer group:notify
├── accounting/                 # Consumer group:acct
├── analytics/                  # Consumer group:analytics
└── frontend/                   # Vite + React dashboard
```

### Data flow

```
Browser
  │ POST /payments
  ▼
Payment Service
  │
  └── single DB transaction:
      ├── INSERT INTO payments (payment_id, amount, status='pending', ...)
      └── INSERT INTO outbox   (topic='payments.created', payload=..., published=false)
          ▲
          │  [without outbox worker: event never reaches Kafka — chaos mode]
          │
Outbox Worker (polls outbox WHERE published=false)
  │
  └── publishes → [ payments.created ]  topic, 12 partitions, key=payment_id
                      │
          ┌───────────┼────────────┬──────────────┐
          ▼           ▼            ▼              ▼
    FraudService  Notifier    Accounting      Analytics
    group:fraud   group:notify group:acct  group:analytics
    200ms delay   instant      instant      instant
          │
          └── publishes → [ payments.fraud-checked ]
                              │
                        Payment Service
                        (PATCH payments SET status=approved|rejected)

Each consumer also writes its result row to MySQL (for SSE feed):
  fraud_results, notifications, accounting_entries, analytics_events
```

### SSE feed

`GET /events` (Payment Service) streams `text/event-stream`. On each consumer result write to MySQL, Payment Service detects the update (polling `consumer_events` table every 500ms) and pushes an SSE event to all connected browsers.

---

## Domain Model

### MySQL tables (in `kafka/` own container, DB: `kafka_payments`)

```sql
payments (
  payment_id  VARCHAR(36) PK,
  amount      DECIMAL(12,2),
  currency    CHAR(3),
  status      ENUM('pending','approved','rejected') DEFAULT 'pending',
  created_at  DATETIME
)

outbox (
  id          BIGINT AUTO_INCREMENT PK,
  topic       VARCHAR(128),
  payload     JSON,
  published   BOOLEAN DEFAULT false,
  created_at  DATETIME
)

consumer_events (
  id           BIGINT AUTO_INCREMENT PK,
  payment_id   VARCHAR(36),
  consumer     ENUM('fraud','notifier','accounting','analytics'),
  result       JSON,        -- consumer-specific outcome
  processed_at DATETIME
)
```

---

## Kafka Config

| Setting | Local (dev) | Production (documented only) |
|---|---|---|
| Brokers | 3 (kafka1/2/3) | 3+ |
| Replication factor | 3 | 3 |
| min.insync.replicas | 2 | 2 |
| acks | all | all |
| enable.idempotence | true | true |
| retries | 10 | 10 |
| partitions (payments.created) | 12 | 12 |
| partitions (payments.fraud-checked) | 12 | 12 |

---

## Services

### Payment Service (`payment-service/`)

- **Runtime**: Node.js + TypeScript + Express 5
- **Port**: 3010
- **Endpoints**:
  - `POST /payments` — body: `{ amount, currency }`. Generates `payment_id` (UUID). Writes DB transaction (payments + outbox). Returns `{ payment_id, status }`.
  - `GET /payments/:id` — returns payment row + all consumer_events for that payment
  - `GET /events` — SSE stream; pushes `consumer_events` updates every 500ms poll
  - `GET /health`
- **Chaos mode**: env var `CHAOS_DUAL_WRITE=true` → throws after DB write, before Outbox Worker can publish. Controlled via UI toggle (calls `POST /chaos` to flip in-memory flag without restart).

### Outbox Worker (`outbox-worker/`)

- **Runtime**: Node.js + TypeScript
- Polls `outbox WHERE published=false ORDER BY id LIMIT 50` every 200ms
- Publishes each row to Kafka using KafkaJS (`acks: -1`, idempotent producer)
- Marks `published=true` after successful send
- Logs lag (unpublished count) every 10s

### FraudService (`fraud-service/`)

- Consumer group: `fraud`
- Consumes `payments.created`
- Simulates 200ms ML delay
- Random result: 95% approved, 5% rejected (seeded by amount: amount > 9000 → rejected)
- Publishes to `payments.fraud-checked`: `{ payment_id, result: 'approved'|'rejected', latency_ms }`
- Writes row to `consumer_events`

### Notifier (`notifier/`)

- Consumer group: `notify`
- Consumes `payments.created`
- Logs "notification sent" + writes `consumer_events`
- No delay

### Accounting (`accounting/`)

- Consumer group: `acct`
- Consumes `payments.created`
- Writes ledger entry to `consumer_events` (debit/credit columns)

### Analytics (`analytics/`)

- Consumer group: `analytics`
- Consumes `payments.created`
- Writes aggregate-ready row to `consumer_events` (amount, currency, hour bucket)

### Payment Service — fraud result consumer

- Separate consumer group: `payment-service-fraud`
- Consumes `payments.fraud-checked`
- Updates `payments.status = approved | rejected`

---

## Frontend (`frontend/`)

**Stack**: Vite + React 19 + TailwindCSS v4 (same as main template)
**Port**: 5174

### Views

#### Dashboard (single page)

```
┌─────────────────────────────────────────────────┐
│  Kafka Payment Pipeline                 [Chaos ●]│
├─────────────────────────────────────────────────┤
│  Submit Payment                                  │
│  Amount: [______]  Currency: [USD▼]  [Submit]   │
├─────────────────────────────────────────────────┤
│  Live Feed                                       │
│  ┌──────────────────────────────────────────┐   │
│  │ 12:01:05  payment_id: abc123             │   │
│  │   [pending] → [fraud:✓ approved 203ms]   │   │
│  │            → [notify:✓ sent]             │   │
│  │            → [acct:✓ recorded]           │   │
│  │            → [analytics:✓ logged]        │   │
│  │            → [APPROVED]                  │   │
│  ├──────────────────────────────────────────┤   │
│  │ 12:01:03  payment_id: def456  [pending]  │   │
│  │   (events arriving...)                   │   │
│  └──────────────────────────────────────────┘   │
├─────────────────────────────────────────────────┤
│  Chaos Mode: OFF  [Toggle]                       │
│  When ON: Payment Service crashes after DB write │
│  but before Outbox publishes. Events never reach │
│  consumers. Toggle Outbox Worker to recover.     │
│                                [Stop Outbox]     │
└─────────────────────────────────────────────────┘
```

### Chaos UX flow

1. User toggles Chaos ON → `POST /chaos { enabled: true }` → Payment Service sets in-memory flag
2. User submits payment → payment appears in feed as `[pending]` — no consumer events arrive
3. User sees "Outbox: X unpublished" counter rising
4. User toggles Chaos OFF + Outbox Worker resumes → events flush, feed catches up

---

## API Contract

Base: `http://localhost:3010`

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/payments` | `{ amount: number, currency: string }` | `{ data: { payment_id, status } }` |
| GET | `/payments/:id` | — | `{ data: { payment, consumer_events[] } }` |
| GET | `/events` | — | SSE stream |
| GET | `/health` | — | `{ status, uptime, db, kafka }` |
| POST | `/chaos` | `{ enabled: boolean }` | `{ chaos: boolean }` |
| POST | `/outbox/pause` | `{ paused: boolean }` | `{ paused: boolean }` (controls outbox worker via HTTP) |

---

## Error Handling

- Payment Service: Zod validation on POST body. Invalid → 400 `{ error: { code, message } }`
- Outbox Worker: retry failed Kafka publishes 3×, then log error + skip (do not mark published)
- Consumers: at-least-once delivery; each consumer is idempotent (upsert by `payment_id + consumer`)
- SSE: client reconnects automatically (EventSource built-in retry)

---

## Infrastructure (`kafka/docker-compose.yml`)

Services:
- `zookeeper` (confluentinc/cp-zookeeper)
- `kafka1`, `kafka2`, `kafka3` (confluentinc/cp-kafka) — RF=3 cluster
- `kafka-init` — one-shot container: creates topics with correct partition/RF config
- `mysql` — MySQL 8.4, DB `kafka_payments`, runs migrations on start
- `payment-service` — port 3010
- `outbox-worker`
- `fraud-service`
- `notifier`
- `accounting`
- `analytics`
- `frontend` — port 5174

All services on `kafka-net` bridge network.

---

## manage script (`kafka/manage.sh`)

```
./manage.sh start    # docker compose up --build
./manage.sh stop     # docker compose down
./manage.sh status   # docker compose ps
./manage.sh logs [service]
./manage.sh reset-db # drop + recreate kafka_payments
```

---

## Open Questions

1. **Outbox pause endpoint** — Outbox Worker needs an HTTP server to receive pause/resume from Payment Service. Add a minimal Express listener on port 3011, or use a shared flag in MySQL.
2. **Consumer lag visibility** — Show per-consumer-group lag in the dashboard? Requires Kafka Admin API call. Nice-to-have, not MVP.
3. **KafkaJS vs kafkajs** — Use `kafkajs` (maintained fork) or original `kafkajs`. Check npm for latest recommended package at implementation time.
