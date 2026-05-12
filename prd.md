# Full-Stack Template — PRD

## Purpose

Study project. Simple, production-grade, extensible full-stack app.
Golden-standard patterns as of early 2026. Not a toy, not over-engineered.

---

## Goals

- Demonstrate best-practice architecture for each layer
- Easy to extend: add backends (Java, Python), swap DB, plug in OTEL/Kafka later
- Deployable natively (dev) or fully via Docker (prod-like)

## Non-Goals

- Auth/authorization
- Testing (out of scope for now)
- Multi-tenancy
- CI/CD pipelines

---

## Tech Stack

| Layer      | Technology                                              | Version policy       |
|------------|---------------------------------------------------------|----------------------|
| Runtime    | Node.js                                                 | 22 LTS               |
| Backend    | Express 5, TypeScript 5, Drizzle ORM, Pino             | stable/LTS           |
| Frontend   | React 19, Vite 6, TanStack Router v1, TanStack Query v5, Tailwind CSS v4, TypeScript 5 | stable/LTS |
| Database   | MySQL 8.4                                               | Docker only          |
| Packaging  | npm (no workspaces — services fully independent)        |                      |
| Containers | Docker + Compose v2                                     |                      |
| Modules    | ESM throughout (no CommonJS)                            |                      |

---

## Project Structure

```
/
├── backend/
│   └── nodejs/          # Node.js + Express (this PRD)
│   # future: java/, python/
├── front/
│   └── react/           # Vite + React (this PRD)
├── db/
│   └── mysql/
│       ├── migrations/  # versioned .sql files (V001__, V002__, ...)
│       └── seed/        # seed data SQL
├── docker-compose.yml   # full Docker deployment
├── docker-compose.dev.yml # DB-only for native dev
└── manage.sh            # unified bash control script
```

Each service (`backend/nodejs/`, `front/react/`) is self-contained:
own `package.json`, `tsconfig.json`, `.env.example`, `Dockerfile`.

---

## Backend — `backend/nodejs/`

### Stack

- **Express 5** — async error handling built-in
- **TypeScript 5** — strict mode, ESM
- **Drizzle ORM** — type-safe SQL-first ORM, MySQL2 driver
- **Pino** — structured JSON logging
- **Zod** — request validation / schema parsing
- **Multer** — file upload handling

### Structure

```
backend/nodejs/
├── src/
│   ├── index.ts              # bootstrap: create app, connect DB, start server
│   ├── app.ts                # Express app factory (exported for testing)
│   ├── config.ts             # typed env config via process.env + Zod
│   ├── logger.ts             # Pino instance, exported singleton
│   ├── db/
│   │   ├── client.ts         # Drizzle + MySQL2 pool setup
│   │   └── schema/
│   │       └── products.ts   # Drizzle schema definition
│   ├── middleware/
│   │   ├── requestLogger.ts  # Pino HTTP request/response logging
│   │   ├── errorHandler.ts   # global Express error handler
│   │   └── validate.ts       # Zod validation middleware factory
│   ├── storage/
│   │   ├── storage.interface.ts  # StorageProvider interface
│   │   └── local.storage.ts      # LocalDiskStorage implements StorageProvider
│   ├── products/
│   │   ├── products.router.ts
│   │   ├── products.controller.ts
│   │   ├── products.service.ts
│   │   └── products.schema.ts    # Zod schemas for request/response
│   └── events/
│       └── event-bus.interface.ts  # DomainEventBus interface (no-op impl for now)
├── uploads/                  # local file storage (gitignored)
├── Dockerfile
├── .env.example
├── drizzle.config.ts
├── package.json
└── tsconfig.json
```

### Configuration (`config.ts`)

All config via environment variables, validated with Zod at startup.
App crashes on missing required vars — fast fail, no silent defaults.

```
PORT=3000
DATABASE_URL=mysql://user:password@localhost:3306/template_db
UPLOAD_DIR=./uploads
MAX_FILE_SIZE_MB=10
NODE_ENV=development
```

### Logging

Pino configured for structured JSON output. Every log line includes:

- `level`, `time`, `msg`
- `service: "backend-nodejs"`
- `env: NODE_ENV`

Request logger middleware adds per-request fields:

- `requestId` — UUID generated per request, set on `res.locals` and logged
- `method`, `url`, `statusCode`, `responseTimeMs`
- `requestId` propagated as `X-Request-Id` response header

**OTEL-ready**: `requestId` field is the placeholder for future `traceId`/`spanId`.
When OTEL is added, swap `requestId` generation for OTEL context propagation —
no structural logging changes required.

Log levels:
- `info` — request lifecycle, startup, DB connection
- `warn` — recoverable issues (validation failures, not-found)
- `error` — unhandled errors with full stack

In production (`NODE_ENV=production`), log level = `info`, no pretty-printing.
In development, use `pino-pretty` for human-readable output.

### File Storage Abstraction

```typescript
interface StorageProvider {
  save(file: Buffer, filename: string, mimetype: string): Promise<string>; // returns URL/path
  delete(path: string): Promise<void>;
  getUrl(path: string): string;
}
```

`LocalDiskStorage` implements this interface, writing to `UPLOAD_DIR`.
To switch to S3: implement `S3Storage` against the same interface, swap in `config.ts`.
No other code changes required.

### Domain Events (Kafka-ready)

```typescript
interface DomainEvent {
  type: string;
  payload: unknown;
  occurredAt: Date;
}

interface DomainEventBus {
  publish(event: DomainEvent): Promise<void>;
}
```

`NoOpEventBus` is the default implementation (logs event at `debug` level, does nothing).
`ProductsService` calls `eventBus.publish(...)` after mutating operations (create, update, delete).
To add Kafka: implement `KafkaEventBus`, inject via config.
Service layer unchanged.

### API Endpoints

Base path: `/api/v1`

| Method | Path                        | Description                      |
|--------|-----------------------------|----------------------------------|
| GET    | `/products`                 | List all products (paginated)    |
| GET    | `/products/:id`             | Get single product               |
| POST   | `/products`                 | Create product                   |
| PUT    | `/products/:id`             | Update product                   |
| DELETE | `/products/:id`             | Delete product                   |
| POST   | `/products/:id/image`       | Upload product image (multipart) |
| GET    | `/health`                   | Health check                     |

All responses: `Content-Type: application/json`.
Error shape: `{ error: { code: string, message: string } }`.
Success list shape: `{ data: Product[], meta: { total, page, limit } }`.
Success single shape: `{ data: Product }`.

### Health Check

`GET /health` returns:

```json
{
  "status": "ok",
  "uptime": 123.45,
  "db": "ok"
}
```

DB check: single `SELECT 1` via Drizzle. Returns `"db": "error"` (not 500) if DB unreachable.

---

## Database — `db/mysql/`

### Schema — `products` table

| Column       | Type             | Notes                        |
|--------------|------------------|------------------------------|
| id           | INT UNSIGNED PK  | AUTO_INCREMENT               |
| name         | VARCHAR(255)     | NOT NULL                     |
| description  | TEXT             |                              |
| price        | DECIMAL(10,2)    | NOT NULL, >= 0               |
| stock        | INT UNSIGNED     | NOT NULL, default 0          |
| image_path   | VARCHAR(500)     | nullable, local path or URL  |
| created_at   | DATETIME         | DEFAULT CURRENT_TIMESTAMP    |
| updated_at   | DATETIME         | ON UPDATE CURRENT_TIMESTAMP  |

### Migrations

Located in `db/mysql/migrations/`. Naming: `V001__create_products.sql`, `V002__...`.
Applied in order on first container start via Docker entrypoint.
Drizzle Kit used for generating migration files from schema changes (`drizzle-kit generate`).
Drizzle Kit also used for applying migrations in local dev (`drizzle-kit migrate`).

### Seed Data

`db/mysql/seed/seed.sql` — 10 sample products inserted on first run (dev/Docker only).
Seed runs only if `products` table is empty (idempotent).

---

## Frontend — `front/react/`

Purpose: visualize the backend data. Minimal UI, functional, clean.

### Stack

- **Vite 6** — build tool and dev server
- **React 19** — UI
- **TanStack Router v1** — file-based routing, type-safe
- **TanStack Query v5** — server state, caching, loading/error states
- **Tailwind CSS v4** — utility-first styling
- **TypeScript 5** — strict mode, ESM

### Structure

```
front/react/
├── src/
│   ├── main.tsx
│   ├── router.tsx            # TanStack Router setup
│   ├── api/
│   │   └── products.ts       # fetch functions (used by Query hooks)
│   ├── routes/
│   │   ├── index.tsx         # Home page
│   │   ├── products/
│   │   │   ├── index.tsx     # Product list page
│   │   │   └── $id.tsx       # Product detail page
│   └── components/
│       ├── Layout.tsx        # shared nav + page wrapper
│       └── ProductCard.tsx
├── Dockerfile
├── nginx.conf                # used in Docker build (serves dist/)
├── .env.example
├── package.json
├── tsconfig.json
└── vite.config.ts
```

### Pages

**Home** (`/`) — title, short description, link to product list.

**Product List** (`/products`) — table/grid of products fetched via TanStack Query.
Shows: name, price, stock. Click row → detail page.
Loading and error states handled.

**Product Detail** (`/products/:id`) — full product info, image if present.

### Environment Config

```
VITE_API_BASE_URL=http://localhost:3000/api/v1
```

### Frontend Logging

No dedicated logging library. `console.error` for caught errors only.
Future: structured FE logging (e.g. OpenTelemetry browser SDK) can be added to `src/logger.ts`.

---

## Deployment

### Docker Images

**Backend** — multi-stage:
1. `node:22-alpine` builder: install deps, compile TS
2. `node:22-alpine` runner: copy dist, run with `node`

**Frontend** — multi-stage:
1. `node:22-alpine` builder: install deps, `vite build`
2. `nginx:alpine` runner: serve `dist/` via nginx

**DB** — official `mysql:8.4` image, no custom image.

### `docker-compose.yml` — Full Stack

All three services. Internal Docker network. Named volumes for DB data and uploads.

```
services:
  db:       mysql:8.4
  backend:  ./backend/nodejs/Dockerfile
  frontend: ./front/react/Dockerfile
```

Backend waits for DB healthcheck before starting (`depends_on: condition: service_healthy`).

### `docker-compose.dev.yml` — DB Only

For native dev mode. Starts only MySQL, exposes port 3306.

### `manage.sh`

Unified bash control script. Bash (not POSIX sh). Requires bash 4+.

```
Usage: ./manage.sh <command> [mode]

Commands:
  start [native|docker]   Start services (default: native)
  stop  [native|docker]   Stop services
  status                  Show running service status
  logs  [service]         Tail logs (service: backend|frontend|db|all)
  rebuild                 Rebuild Docker images
  reset-db                Drop and recreate DB, re-run migrations + seed

Modes:
  native  — BE and FE run locally via npm, DB in Docker (uses docker-compose.dev.yml)
  docker  — all via docker-compose.yml
```

Native mode:
- Starts DB via `docker-compose.dev.yml`
- Starts BE: `npm run dev` in `backend/nodejs/`
- Starts FE: `npm run dev` in `front/react/`
- Stores PIDs in `.pids/` for clean stop

Script validates prerequisites on startup: `node`, `npm`, `docker`, `docker compose`.

---

## Extension Points (not implemented, ready for)

| Concern        | How to add                                                    |
|----------------|---------------------------------------------------------------|
| OTEL tracing   | Replace `requestId` with OTEL context; add SDK to `index.ts` |
| OTEL metrics   | Mount Prometheus endpoint; add to health check               |
| Kafka events   | Implement `KafkaEventBus`, inject in `index.ts`               |
| S3 storage     | Implement `S3Storage`, swap in `config.ts`                    |
| New backend    | Add `backend/java/` or `backend/python/` — same API contract |
| Auth           | Add middleware layer before routers                           |
| DB migrations tool | Swap Drizzle Kit for Flyway (already using same `V001__` naming convention) |
