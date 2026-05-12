
## What this is

Study project: production-grade full-stack template. `prd.md` defines **target** architecture (TypeScript, Drizzle ORM, TanStack Router, etc.). Current code: earlier iteration — plain JS/CommonJS backend, React 18 + react-router-dom, no TypeScript.

Implementing features: follow `prd.md` patterns (TypeScript, ESM, Drizzle, Pino, Zod, TanStack Router/Query, Tailwind v4) even if existing files don't yet.

## Commands

### Backend (`backend/nodejs/`)
```bash
npm install
npm run dev      # nodemon, port 3000
npm start        # production
```

### Frontend (`front/react/`)
```bash
npm install
npm run dev      # Vite, port 5173
npm run build
npm run preview
```

### Full stack via `manage.sh` (target) / `deploy.sh` (current)
```bash
./deploy.sh start [native|docker]   # default: docker
./deploy.sh stop
./deploy.sh status
./deploy.sh logs [backend|frontend|db|all]
./deploy.sh rebuild
./deploy.sh reset-db
```

- **native mode**: DB in Docker (`docker-compose.dev.yml`), BE+FE via `npm run dev`
- **docker mode**: all services via `docker-compose.yml`

No test framework yet.

## Architecture

### Current backend (`backend/nodejs/src/`)
- Plain JS, CommonJS (`require`/`module.exports`), Express 4
- `index.js` — bootstrap + route mounting
- `mysql2` pool (no ORM), `multer` uploads, `dotenv` config
- Error shape: `{ error: string }`, success: direct JSON

### Target backend (per `prd.md`)
- TypeScript 5, ESM, Express 5
- **Layers**: `config.ts` → `db/client.ts` (Drizzle + MySQL2) → `{resource}/service.ts` → `{resource}/controller.ts` → `{resource}/router.ts`
- `StorageProvider` interface — swap local disk → S3 without touching other code
- `DomainEventBus` interface — `NoOpEventBus` default, Kafka-ready
- Pino structured JSON logging; every request gets `requestId` (future OTEL `traceId` slot)
- Zod for all request validation and env config

### Current frontend (`front/react/src/`)
- React 18, JSX, ESM, Vite 5
- `react-router-dom` v6, raw `fetch()`, `useState`/`useEffect` pattern

### Target frontend (per `prd.md`)
- React 19, TypeScript, Vite 6
- TanStack Router v1 (file-based routes in `src/routes/`)
- TanStack Query v5 — all server state; no manual `useEffect` fetching
- Tailwind CSS v4

### Database (`db/mysql/`)
- MySQL 8.4 (Docker only)
- Migrations: `db/mysql/migrations/V001__name.sql` (Flyway-compatible)
- Drizzle Kit generates/applies migrations in dev
- Seed: `db/mysql/seed/seed.sql`, idempotent (runs only if table empty)

### API contract
Base path: `/api/v1`. All responses JSON.
- Error: `{ error: { code: string, message: string } }`
- List: `{ data: T[], meta: { total, page, limit } }`
- Single: `{ data: T }`
- Health: `GET /health` → `{ status, uptime, db }`

## Code style (current codebase)

**Backend**: 2-space indent, semicolons, single quotes, `snake_case` filenames, `camelCase` vars. Parameterized SQL only (`?` placeholders).

**Frontend**: no semicolons, `PascalCase.jsx` components, functional only, early returns for loading/error states.

## Extension points (design intent)

| Concern | How |
|---|---|
| S3 storage | Implement `S3Storage` vs `StorageProvider` interface, swap in `config.ts` |
| Kafka | Implement `KafkaEventBus` vs `DomainEventBus`, inject in `index.ts` |
| OTEL tracing | Replace `requestId` with OTEL context in request logger |
| New backend | Add `backend/java/` or `backend/python/` — same API contract |
| Auth | Middleware layer before routers |