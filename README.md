# Full-Stack Template

Production-grade full-stack template. Study project demonstrating best-practice architecture for each layer as of 2026.

## Stack

| Layer | Tech |
|---|---|
| Backend | Node.js 22, Express 5, TypeScript 5, Drizzle ORM, Pino, Zod |
| Frontend | React 19, Vite 6, TanStack Router v1, TanStack Query v5, Tailwind v4, TypeScript 5 |
| Database | MySQL 8.4 (Docker) |
| Containers | Docker + Compose v2 |

## Structure

```
backend/nodejs/     — Express API (port 3000)
front/react/        — React SPA (port 5173 dev / 80 docker)
db/mysql/
  migrations/       — versioned SQL (V001__name.sql)
  seed/             — seed.sql (idempotent)
docker-compose.yml           — full Docker stack
docker-compose.db-dev.yml    — DB-only for native dev
manage.sh                    — unified control script
```

## Quick Start

### First run (required once)

```bash
cd backend/nodejs && npm run db:generate
```

### Run

```bash
./manage.sh
```

```
  Template Manager

   1) Start   — docker  (all services in containers, :80 / :3000)
   2) Start   — native  (DB in Docker, BE+FE local, :5173 / :3000)
   3) Stop    — docker
   4) Stop    — native
   5) Status
   6) Logs    — backend
   7) Logs    — frontend
   8) Logs    — db
   9) Rebuild — docker  (reinstall deps + rebuild images)
  10) Rebuild — native
  11) Reset DB — docker (drop volume, re-migrate, re-seed)
  12) Reset DB — native
   0) Exit
```

**Option 1 — docker**: full stack in containers. Frontend at http://localhost:80, API at http://localhost:3000.

**Option 2 — native**: DB in Docker, BE+FE run locally with hot reload. Frontend at http://localhost:5173, API at http://localhost:3000.

Or non-interactively:

```bash
./manage.sh start  [docker|native]
./manage.sh stop   [docker|native]
./manage.sh status
./manage.sh logs   [backend|frontend|db|all]
./manage.sh rebuild  [docker|native]
./manage.sh reset-db [docker|native]
```

## Backend Commands

```bash
cd backend/nodejs
npm run dev          # tsx watch
npm run build        # tsc
npm start            # node dist/index.js
npm run db:generate  # drizzle-kit generate → db/mysql/migrations/
npm run db:migrate   # run pending migrations
npm run db:seed      # run db/mysql/seed/seed.sql
```

## Frontend Commands

```bash
cd front/react
npm run dev      # Vite dev server
npm run build    # tsc + vite build
npm run preview
```

## API Contract

Base path: `/api/v1`

| Shape | Format |
|---|---|
| Success (single) | `{ data: T }` |
| Success (list) | `{ data: T[], meta: { total, page, limit } }` |
| Error | `{ error: { code: string, message: string } }` |
| Health | `GET /health` → `{ status, uptime, db }` |

## Extending

| Concern | How |
|---|---|
| New resource | Add `{resource}/` in `backend/nodejs/src/` with schema/service/controller/router; mount in `index.ts` |
| S3 storage | Implement `StorageProvider` interface, swap in `config.ts` |
| Kafka | Implement `DomainEventBus` interface, inject in `index.ts` |
| Auth | Add middleware before routers |
| OTEL | Replace `requestId` middleware with OTEL context propagation |

## Notes

- Docker build uses `network: host` — required for WSL2 DNS during `npm ci`
- `VITE_API_BASE_URL` defaults to `/api/v1` (Docker nginx proxy); set to `http://localhost:3000/api/v1` for native dev
- Migrations must exist before `manage.sh start` — generate them first
