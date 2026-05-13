# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Study project: production-grade full-stack template. `prd.md` (in `.MY-FILES/`) defines the target architecture. The codebase is currently mid-migration — backend is fully on the target stack (TypeScript, Drizzle, Pino, Zod, Express 5), frontend is fully on the target stack (React 19, TanStack Router v1, TanStack Query v5, Tailwind v4).

When implementing features, follow target patterns: TypeScript, ESM, Drizzle, Pino, Zod, TanStack Router/Query, Tailwind v4.

## Commands

### Backend (`backend/nodejs/`)
```bash
npm run dev          # tsx watch, port 3000
npm run build        # tsc
npm start            # node dist/index.js
npm run db:generate  # drizzle-kit generate → db/mysql/migrations/
npm run db:migrate   # drizzle-kit migrate (runs pending migrations)
npm run db:seed      # run db/mysql/seed/seed.sql
```

### Frontend (`front/react/`)
```bash
npm run dev      # Vite, port 5173
npm run build    # tsc + vite build
npm run preview
```

### Full stack via `manage.sh`
```bash
./manage.sh              # interactive menu (recommended)
./manage.sh start [native|docker]
./manage.sh stop  [native|docker]
./manage.sh status
./manage.sh logs  [backend|frontend|db|all]
./manage.sh rebuild [native|docker]
./manage.sh reset-db [native|docker]
```

- **native mode**: DB in Docker (`docker-compose.db-dev.yml`), BE+FE via `npm run dev` (hot reload, :5173/:3000)
- **docker mode**: all services via `docker-compose.yml` (:80/:3000)

### First run (required before `manage.sh start`)
```bash
cd backend/nodejs && npm run db:generate   # generates db/mysql/migrations/ from schema
```
Migrations must exist before Docker or native start — `manage.sh` runs them post-healthcheck but cannot generate them.

No test framework yet.

## Architecture

### Backend (`backend/nodejs/src/`)

TypeScript 5, ESM, Express 5. Layered per resource:

```
config.ts              — Zod-validated env config (single source of truth)
logger.ts              — Pino structured JSON logger
db/client.ts           — Drizzle + mysql2 pool; db/schema/*.ts for schemas
errors.ts              — AppError(status, code, message)
middleware/            — request logger (requestId), error handler, multer upload
storage/               — StorageProvider interface + LocalStorage impl
events/                — DomainEventBus interface + NoOpEventBus impl
{resource}/
  *.schema.ts          — Drizzle table def + Zod validation schemas
  *.service.ts         — business logic, talks to db
  *.controller.ts      — req/res handling, calls service
  *.router.ts          — Express router, mounts controller handlers
index.ts               — bootstrap: create app, mount routers, start server
migrate.ts             — standalone migrator (not imported by index.ts); Docker runs it via
                         `node dist/migrate.js`; reads `MIGRATIONS_DIR` env var or falls back
                         to `../../db/mysql/migrations` relative to dist/ (works locally only)
```

Drizzle migrations output to `db/mysql/migrations/` (Flyway-compatible naming `V001__name.sql`).

### Frontend (`front/react/src/`)

React 19, TypeScript, Vite 6, TanStack Router v1 (file-based), TanStack Query v5, Tailwind v4.

```
routes/                — file-based routes (TanStack Router)
  __root.tsx           — root layout
  index.tsx            — home /
  {resource}/          — resource routes ($id.tsx, $id.edit.tsx, create.tsx, index.tsx)
api/                   — typed fetch wrappers per resource (no raw fetch in components)
```

Route file naming: `$id.tsx` → `/products/123`, `$id.edit.tsx` → `/products/123/edit`.
Route tree is auto-generated into `routeTree.gen.ts` — do not edit manually.

### Database (`db/mysql/`)
- MySQL 8.4 (Docker only)
- Migrations: `db/mysql/migrations/V001__name.sql`
- Seed: `db/mysql/seed/seed.sql` — idempotent (runs only if table empty)

### API contract
Base path: `/api/v1`. All responses JSON.
- Error: `{ error: { code: string, message: string } }`
- List: `{ data: T[], meta: { total, page, limit } }`
- Single: `{ data: T }`
- Health: `GET /health` → `{ status, uptime, db }`

## Extension points

| Concern | How |
|---|---|
| S3 storage | Implement `S3Storage` vs `StorageProvider` interface, swap in `config.ts` |
| Kafka | Implement `KafkaEventBus` vs `DomainEventBus`, inject in `index.ts` |
| OTEL tracing | Replace `requestId` with OTEL context in request logger middleware |
| New resource | Add `{resource}/` dir with schema/service/controller/router; mount router in `app.ts` |
| Auth | Middleware layer before routers |

## Code style

**Backend**: 2-space indent, semicolons, single quotes, `snake_case` filenames, `camelCase` vars. All DB queries through Drizzle (no raw SQL except migrations/seed).

**Frontend**: no semicolons, `PascalCase` component files, functional only, early returns for loading/error states. All server state via TanStack Query (no manual `useEffect` fetching).

## Docker notes

- `docker-compose.yml` build stanzas use `network: host` — required for WSL2 where Docker bridge DNS fails during `npm ci`.
- `MIGRATIONS_DIR=/app/migrations` is set in docker-compose; migrations are volume-mounted (`db/mysql/migrations:/app/migrations:ro`). Do not rely on relative `__dirname` paths from `dist/` inside containers.
- `VITE_API_BASE_URL` defaults to `/api/v1` in `src/api/products.ts` when env var is unset — correct for Docker (nginx proxies `/api/` to backend). For native dev, set it to `http://localhost:3000/api/v1`.
