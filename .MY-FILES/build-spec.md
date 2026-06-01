# Full-Stack Rebuild Spec — v2

**Slug:** `fullstack-rebuild`
**Date:** 2026-05-13
**Changes from v1:** Migration ownership resolved (Drizzle Kit only, no initdb.d for migrations). `ProductsController` constructor fixed (takes `storage`). `description` Zod schema nullish. `validate` middleware passes through `next()`. `LocalDiskStorage` uses UUID filename. `MulterError` converted to AppError. Graceful shutdown added. `routeTree.gen.ts` committed. `reset-db` specified.

---

## §1 Summary

Complete rewrite: plain JS/CJS/React 18 → TypeScript 5 ESM stack per `prd.md`. Entity renamed `items → products` (new schema: price, stock, image_path). Frontend extends PRD read-only spec to include Create+Edit (user decision). All layers replaced simultaneously. `deploy.sh → manage.sh`, `docker-compose.dev.yml` at repo root. **Single migration authority: Drizzle Kit in both native and Docker modes.** `manage.sh start` runs `db:migrate` after DB healthcheck in both modes.

---

## §2 Stack Snapshot

| Layer | Current | Target |
|---|---|---|
| Runtime | Node 18 | Node 22 LTS |
| Backend | Express 4, plain JS, CJS | Express 5, TypeScript 5 strict, ESM |
| ORM/DB | mysql2 raw pool | Drizzle ORM 0.38+, mysql2 3.x |
| Validation | none | Zod 3 |
| Logging | console.log | Pino 9 structured JSON |
| Dev runner | nodemon | tsx watch |
| Frontend | React 18, JSX | React 19, TypeScript 5 strict, ESM |
| Build | Vite 5 | Vite 6 |
| Routing | react-router-dom v6 | TanStack Router v1 (file-based) |
| Server state | useState + fetch | TanStack Query v5 |
| Styling | hand-written CSS | Tailwind CSS v4 |
| DB | MySQL 8.0 Docker | MySQL 8.4 Docker |
| Containers | Compose v2 | Compose v2, multi-stage images |
| Modules | CJS/ESM mixed | ESM throughout |

TypeScript: strict mode, `NodeNext` resolution (backend), `Bundler` (frontend).

---

## §3 Architecture Patterns Applied

- **Layered backend**: router → controller → service → db/client
- **StorageProvider interface**: `LocalDiskStorage` default; S3 swap = new impl only
- **DomainEventBus interface**: `NoOpEventBus` via constructor injection; Kafka = new impl + one line in `index.ts`
- **Observability**: Pino structured JSON, `requestId` per request (OTEL `traceId` slot)
- **TanStack Query**: all server state; zero manual `useEffect` fetching
- **TanStack Router v1 file-based**: `routeTree.gen.ts` auto-generated, committed to repo

---

## §4 Design Decisions

1. **Complete rewrite**: study project, no prod data. Incremental migration adds noise with no benefit.
2. **items → products**: fresh `V001` migration (Drizzle-generated). Old `V1__init.sql` deleted.
3. **Full CRUD frontend**: user decision — List + Detail + Create + Edit. Mutations via TanStack Query `useMutation`.
4. **Drizzle Kit as sole migration authority (native dev)**: `npm run db:migrate` (drizzle-kit) for native dev. **Programmatic migrator for Docker**: `drizzle-kit` is a devDependency — absent in prod image. `src/migrate.ts` uses `drizzle-orm/mysql2/migrator` (runtime dep). Compiles to `dist/migrate.js`. `manage.sh` runs `docker compose exec backend node dist/migrate.js` in Docker mode. `__drizzle_migrations` is the single ledger in both modes.
5. **Drizzle Kit output dir**: `../../db/mysql/migrations` (relative to `backend/nodejs/`). Drizzle generates numbered SQL files there. Hand-written V001 SQL shown in §6 for schema reference only — actual file on disk is Drizzle-generated.
6. **Seed strategy**: Seed NOT in initdb.d — `products` table doesn't exist at initdb.d time (migrations run via manage.sh post-healthcheck). manage.sh runs seed after migrate: Docker mode: `docker compose exec -T db mysql -utemplate_user -ptemplate_pass template_db < db/mysql/seed/seed.sql`; native mode: same against `localhost:3306`. Requires `mysql-client` on host (documented as prerequisite).
7. **ProductsController owns storage**: `new ProductsController(service, storage)`. Upload flow: router calls `controller.uploadImage` → controller calls `storage.save` → service sets image path. Storage stays out of router.
8. **Filenames server-generated**: `LocalDiskStorage.save` ignores client filename; generates `${randomUUID()}${ext}`. Prevents path traversal.
9. **validate middleware → next()**: All validation errors go through `next(new AppError(400, ...))` — single error-shape writer.
10. **MulterError → AppError**: `upload.single()` wrapped to catch `MulterError` and convert to AppError(400, FILE_UPLOAD_ERROR).
11. **Graceful shutdown**: `SIGTERM` handler closes HTTP server then DB pool.
12. **tsx for dev**, tsc for prod. No compilation step in dev.
13. **routeTree.gen.ts committed**: avoids cold-CI failures. Auto-regenerated on `vite dev`.
14. **deploy.sh → manage.sh** + **docker-compose.dev.yml** at root.

---

## §5 API Contract

Base path: `/api/v1`. All responses `Content-Type: application/json`.

| Method | Path | Auth? | Request | Response | Status codes |
|--------|------|-------|---------|----------|--------------|
| GET | `/api/v1/products` | No | `?page=1&limit=20` | `{data: Product[], meta}` | 200 |
| GET | `/api/v1/products/:id` | No | — | `{data: Product}` | 200, 404 |
| POST | `/api/v1/products` | No | JSON body | `{data: Product}` | 201, 400 |
| PUT | `/api/v1/products/:id` | No | JSON body (partial) | `{data: Product}` | 200, 400, 404 |
| DELETE | `/api/v1/products/:id` | No | — | 204 No Content | 204, 404 |
| POST | `/api/v1/products/:id/image` | No | `multipart/form-data` field `file` | `{data: Product}` | 200, 400, 404 |
| GET | `/health` | No | — | `{status, uptime, db}` | 200 |

**Product shape:**
```json
{
  "id": 1, "name": "Running Shoes", "description": "Lightweight running shoes",
  "price": "89.99", "stock": 50, "image_path": null,
  "created_at": "2026-05-13T10:00:00.000Z", "updated_at": "2026-05-13T10:00:00.000Z"
}
```
`price` is a string (mysql2 serializes DECIMAL as string).

**POST /api/v1/products request:** `{ "name": "X", "price": 89.99, "stock": 50 }`. `description` optional. `stock` optional (default 0). `price` required, ≥ 0.

**Error shape:** `{ "error": { "code": "NOT_FOUND", "message": "..." } }`

**Error codes:** `VALIDATION_ERROR` (400), `NOT_FOUND` (404), `FILE_UPLOAD_ERROR` (400), `INTERNAL_ERROR` (500).

**List response:** `{ "data": [...], "meta": { "total": 42, "page": 1, "limit": 20 } }`

**Health:** `{ "status": "ok", "uptime": 123.45, "db": "ok" }`. `"db": "error"` (not 500) if unreachable.

Pagination defaults: `page=1`, `limit=20`, max `limit=100`.

**`description` semantics:** empty string `""` = null. Clients that submit `description: ""` receive `null` in response.

---

## §6 DB Schema & Migrations

### `products` table

| Column | Type | Nullable | Default |
|--------|------|----------|---------|
| id | INT UNSIGNED PK | No | AUTO_INCREMENT |
| name | VARCHAR(255) | No | — |
| description | TEXT | Yes | NULL |
| price | DECIMAL(10,2) | No | — |
| stock | INT UNSIGNED | No | 0 |
| image_path | VARCHAR(500) | Yes | NULL |
| created_at | DATETIME | No | CURRENT_TIMESTAMP |
| updated_at | DATETIME | Yes | CURRENT_TIMESTAMP ON UPDATE |

### Schema reference SQL (for documentation — actual file is Drizzle-generated)

```sql
CREATE TABLE products (
  id          INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  name        VARCHAR(255)    NOT NULL,
  description TEXT,
  price       DECIMAL(10,2)   NOT NULL,
  stock       INT UNSIGNED    NOT NULL DEFAULT 0,
  image_path  VARCHAR(500),
  created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME                 DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

Down-migration: `DROP TABLE IF EXISTS products;`

**Migration workflow:**
1. Edit `backend/nodejs/src/db/schema/products.ts`
2. `npm run db:generate` → Drizzle writes SQL to `../../db/mysql/migrations/`
3. `npm run db:migrate` → applies pending migrations, updates `__drizzle_migrations` ledger

**Delete:** `db/mysql/migrations/V1__init.sql`

### Drizzle schema

**File:** `backend/nodejs/src/db/schema/products.ts`

```typescript
import { mysqlTable, int, varchar, text, decimal, datetime } from 'drizzle-orm/mysql-core'
import { sql } from 'drizzle-orm'

export const products = mysqlTable('products', {
  id:          int('id').unsigned().primaryKey().autoincrement(),
  name:        varchar('name', { length: 255 }).notNull(),
  description: text('description'),
  price:       decimal('price', { precision: 10, scale: 2 }).notNull(),
  stock:       int('stock').unsigned().notNull().default(0),
  image_path:  varchar('image_path', { length: 500 }),
  created_at:  datetime('created_at').notNull().default(sql`CURRENT_TIMESTAMP`),
  updated_at:  datetime('updated_at').default(sql`CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP`),
})

export type Product = typeof products.$inferSelect
export type NewProduct = typeof products.$inferInsert
```

---

## §7 Backend Implementation Plan

Build order: config → logger → DB schema → Drizzle client → event bus → storage → errors → middleware → Zod schemas → service → controller → router → app → index → Dockerfile.

---

**1. `backend/nodejs/package.json`** — full replace

```json
{
  "name": "backend-nodejs",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js",
    "db:generate": "drizzle-kit generate",
    "db:migrate": "drizzle-kit migrate",
    "db:seed": "mysql -u $DB_USER -p$DB_PASS -h $DB_HOST $DB_NAME < ../../db/mysql/seed/seed.sql"
  },
  "dependencies": {
    "cors": "^2.8.5",
    "dotenv": "^16.4.0",
    "drizzle-orm": "^0.38.0",
    "express": "^5.0.0",
    "multer": "^1.4.5-lts.1",
    "mysql2": "^3.11.0",
    "pino": "^9.0.0",
    "uuid": "^10.0.0",
    "zod": "^3.23.0"
  },
  "devDependencies": {
    "@types/cors": "^2.8.17",
    "@types/express": "^5.0.0",
    "@types/multer": "^1.4.12",
    "@types/node": "^22.0.0",
    "@types/uuid": "^10.0.0",
    "drizzle-kit": "^0.29.0",
    "pino-pretty": "^13.0.0",
    "tsx": "^4.19.0",
    "typescript": "^5.7.0"
  }
}
```

---

**2. `backend/nodejs/tsconfig.json`** — new

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "sourceMap": true
  },
  "include": ["src/**/*", "drizzle.config.ts"],
  "exclude": ["node_modules", "dist"]
}
```

---

**3. `backend/nodejs/.env.example`** — new

```
PORT=3000
DATABASE_URL=mysql://template_user:template_pass@localhost:3306/template_db
UPLOAD_DIR=./uploads
MAX_FILE_SIZE_MB=10
NODE_ENV=development
CORS_ORIGIN=*
```

---

**4. `backend/nodejs/drizzle.config.ts`** — new

```typescript
import type { Config } from 'drizzle-kit'

export default {
  schema: './src/db/schema/*.ts',
  out: '../../db/mysql/migrations',
  dialect: 'mysql',
  dbCredentials: { url: process.env['DATABASE_URL']! },
} satisfies Config
```

`out` points to the shared migrations directory. Do not mount this directory into Docker `initdb.d` — Drizzle writes JSON metadata files alongside SQL that MySQL cannot parse.

---

**5. `backend/nodejs/src/config.ts`** — new

```typescript
import { z } from 'zod'

const envSchema = z.object({
  PORT:             z.string().default('3000').transform(Number),
  DATABASE_URL:     z.string().min(1),
  UPLOAD_DIR:       z.string().default('./uploads'),
  MAX_FILE_SIZE_MB: z.string().default('10').transform(Number),
  NODE_ENV:         z.enum(['development', 'production', 'test']).default('development'),
  CORS_ORIGIN:      z.string().default('*'),
})

export const config = envSchema.parse(process.env)
```

Crashes on missing `DATABASE_URL` — fast fail.

---

**6. `backend/nodejs/src/logger.ts`** — new

```typescript
import pino from 'pino'
import { config } from './config.js'

export const logger = pino(
  {
    level: config.NODE_ENV === 'production' ? 'info' : 'debug',
    base: { service: 'backend-nodejs', env: config.NODE_ENV },
  },
  config.NODE_ENV === 'development'
    ? pino.transport({ target: 'pino-pretty' })
    : undefined,
)
```

---

**7. `backend/nodejs/src/db/client.ts`** — replaces `src/db.js`

```typescript
import { drizzle } from 'drizzle-orm/mysql2'
import mysql from 'mysql2/promise'
import { config } from '../config.js'
import * as schema from './schema/products.js'

const pool = mysql.createPool(config.DATABASE_URL)
export const db = drizzle(pool, { schema, mode: 'default' })
export type Db = typeof db

export const closePool = () => pool.end()
```

---

**8. `backend/nodejs/src/migrate.ts`** — new (programmatic migrator, no drizzle-kit at runtime)

```typescript
import 'dotenv/config'
import { migrate } from 'drizzle-orm/mysql2/migrator'
import { db, closePool } from './db/client.js'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

await migrate(db, { migrationsFolder: path.resolve(__dirname, '../../db/mysql/migrations') })
console.log('Migrations applied')
await closePool()
```

Compiles to `dist/migrate.js`. Used in Docker mode (`docker compose exec backend node dist/migrate.js`). Native dev continues to use `npm run db:migrate` (drizzle-kit, not compiled). The `migrationsFolder` path resolves to `db/mysql/migrations/` from the compiled dist location.

---

**10. `backend/nodejs/src/events/event-bus.interface.ts`** — new

```typescript
export interface DomainEvent {
  type: string
  payload: unknown
  occurredAt: Date
}

export interface DomainEventBus {
  publish(event: DomainEvent): Promise<void>
}

export class NoOpEventBus implements DomainEventBus {
  async publish(_event: DomainEvent): Promise<void> {
    // no-op; swap for KafkaEventBus in index.ts
  }
}
```

---

**11. `backend/nodejs/src/storage/storage.interface.ts`** — new

```typescript
export interface StorageProvider {
  save(file: Buffer, filename: string, mimetype: string): Promise<string>
  delete(path: string): Promise<void>
  getUrl(path: string): string
}
```

---

**10. `backend/nodejs/src/storage/local.storage.ts`** — new

```typescript
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { config } from '../config.js'
import type { StorageProvider } from './storage.interface.js'

export class LocalDiskStorage implements StorageProvider {
  private readonly dir = path.resolve(config.UPLOAD_DIR)

  async save(file: Buffer, originalName: string, _mimetype: string): Promise<string> {
    await fs.mkdir(this.dir, { recursive: true })
    const ext = path.extname(originalName)
    const filename = `${randomUUID()}${ext}`
    await fs.writeFile(path.join(this.dir, filename), file)
    return `/uploads/${filename}`
  }

  async delete(filePath: string): Promise<void> {
    await fs.unlink(path.join(this.dir, path.basename(filePath))).catch(() => undefined)
  }

  getUrl(filePath: string): string {
    return filePath
  }
}
```

Filename is UUID-generated server-side — client-provided name is used only for extension extraction.

---

**11. `backend/nodejs/src/errors.ts`** — new

```typescript
export class AppError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message)
    this.name = 'AppError'
  }
}
```

---

**12. `backend/nodejs/src/middleware/validate.ts`** — new

```typescript
import type { RequestHandler, NextFunction, Request, Response } from 'express'
import type { ZodSchema } from 'zod'
import { AppError } from '../errors.js'

export const validate = (schema: ZodSchema, target: 'body' | 'query' = 'body'): RequestHandler =>
  (req: Request, res: Response, next: NextFunction) => {
    const result = schema.safeParse(req[target])
    if (!result.success) {
      next(new AppError(400, 'VALIDATION_ERROR', result.error.message))
      return
    }
    req[target] = result.data
    next()
  }
```

All validation errors route through the global error handler → consistent response shape.

---

**13. `backend/nodejs/src/middleware/requestLogger.ts`** — new

```typescript
import { randomUUID } from 'node:crypto'
import type { RequestHandler } from 'express'
import { logger } from '../logger.js'

export const requestLogger: RequestHandler = (req, res, next) => {
  const requestId = randomUUID()
  res.locals['requestId'] = requestId
  res.setHeader('X-Request-Id', requestId)

  const start = Date.now()
  res.on('finish', () => {
    logger.info({
      requestId,
      method: req.method,
      url: req.originalUrl,
      statusCode: res.statusCode,
      responseTimeMs: Date.now() - start,
    }, 'request completed')
  })
  next()
}
```

---

**14. `backend/nodejs/src/middleware/errorHandler.ts`** — new

```typescript
import type { ErrorRequestHandler } from 'express'
import { AppError } from '../errors.js'
import { logger } from '../logger.js'

export const errorHandler: ErrorRequestHandler = (err, _req, res, _next) => {
  const requestId = res.locals['requestId'] as string | undefined

  if (err instanceof AppError) {
    logger.warn({ requestId, code: err.code }, err.message)
    res.status(err.status).json({ error: { code: err.code, message: err.message } })
    return
  }

  logger.error({ err, requestId }, 'Unhandled error')
  res.status(500).json({
    error: {
      code: 'INTERNAL_ERROR',
      message: process.env['NODE_ENV'] === 'development' ? (err as Error).message : 'Internal server error',
    },
  })
}
```

`AppError` → `warn` (expected). Unknown error → `error` (unexpected). Two log levels preserve signal clarity.

---

**15. `backend/nodejs/src/products/products.schema.ts`** — new

```typescript
import { z } from 'zod'

const nullishString = z.string().nullish().transform(v => (v === '' ? null : v ?? null))

export const createProductSchema = z.object({
  name:        z.string().min(1).max(255),
  description: nullishString,
  price:       z.number().nonnegative(),
  stock:       z.number().int().nonnegative().optional().default(0),
})

export const updateProductSchema = createProductSchema.partial()

export const paginationSchema = z.object({
  page:  z.coerce.number().int().positive().optional().default(1),
  limit: z.coerce.number().int().positive().max(100).optional().default(20),
})

export type CreateProductInput = z.infer<typeof createProductSchema>
export type UpdateProductInput = z.infer<typeof updateProductSchema>
export type PaginationInput   = z.infer<typeof paginationSchema>
```

`description: ""` → `null`. Matches nullable DB column and `Product` shape.

---

**16. `backend/nodejs/src/products/products.service.ts`** — new

```typescript
import { eq, count, sql } from 'drizzle-orm'
import { products } from '../db/schema/products.js'
import type { Db } from '../db/client.js'
import type { DomainEventBus } from '../events/event-bus.interface.js'
import type { CreateProductInput, PaginationInput, UpdateProductInput } from './products.schema.js'
import { AppError } from '../errors.js'

export class ProductsService {
  constructor(private readonly db: Db, private readonly eventBus: DomainEventBus) {}

  async list({ page, limit }: PaginationInput) {
    const offset = (page - 1) * limit
    const [rows, [{ total }]] = await Promise.all([
      this.db.select().from(products).limit(limit).offset(offset),
      this.db.select({ total: count() }).from(products),
    ])
    return { rows, total: Number(total) }
  }

  async findById(id: number) {
    const [row] = await this.db.select().from(products).where(eq(products.id, id))
    if (!row) throw new AppError(404, 'NOT_FOUND', 'Product not found')
    return row
  }

  async create(dto: CreateProductInput) {
    const [result] = await this.db.insert(products).values(dto)
    const created = await this.findById(result.insertId)
    await this.eventBus.publish({ type: 'product.created', payload: { id: created.id }, occurredAt: new Date() })
    return created
  }

  async update(id: number, dto: UpdateProductInput) {
    await this.findById(id)
    await this.db.update(products).set(dto).where(eq(products.id, id))
    const updated = await this.findById(id)
    await this.eventBus.publish({ type: 'product.updated', payload: { id }, occurredAt: new Date() })
    return updated
  }

  async delete(id: number) {
    await this.findById(id)
    await this.db.delete(products).where(eq(products.id, id))
    await this.eventBus.publish({ type: 'product.deleted', payload: { id }, occurredAt: new Date() })
  }

  async setImage(id: number, imagePath: string) {
    await this.findById(id)
    await this.db.update(products).set({ image_path: imagePath }).where(eq(products.id, id))
    return this.findById(id)
  }
}
```

---

**17. `backend/nodejs/src/products/products.controller.ts`** — new

```typescript
import type { Request, Response, NextFunction } from 'express'
import type { ProductsService } from './products.service.js'
import type { StorageProvider } from '../storage/storage.interface.js'
import { paginationSchema } from './products.schema.js'
import { AppError } from '../errors.js'

export class ProductsController {
  constructor(
    private readonly service: ProductsService,
    private readonly storage: StorageProvider,
  ) {}

  list = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const { page, limit } = paginationSchema.parse(req.query)
      const { rows, total } = await this.service.list({ page, limit })
      res.json({ data: rows, meta: { total, page, limit } })
    } catch (err) { next(err) }
  }

  get = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const product = await this.service.findById(Number(req.params['id']))
      res.json({ data: product })
    } catch (err) { next(err) }
  }

  create = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const product = await this.service.create(req.body)
      res.status(201).json({ data: product })
    } catch (err) { next(err) }
  }

  update = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const product = await this.service.update(Number(req.params['id']), req.body)
      res.json({ data: product })
    } catch (err) { next(err) }
  }

  remove = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      await this.service.delete(Number(req.params['id']))
      res.status(204).end()
    } catch (err) { next(err) }
  }

  uploadImage = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      if (!req.file) throw new AppError(400, 'FILE_UPLOAD_ERROR', 'No file provided')
      const imagePath = await this.storage.save(req.file.buffer, req.file.originalname, req.file.mimetype)
      const product = await this.service.setImage(Number(req.params['id']), imagePath)
      res.json({ data: product })
    } catch (err) { next(err) }
  }
}
```

Controller owns `storage` — upload flow stays in controller, not service.

---

**18. `backend/nodejs/src/products/products.router.ts`** — replaces `src/routes/items.js`

```typescript
import { Router } from 'express'
import multer, { MulterError } from 'multer'
import type { Request, Response, NextFunction } from 'express'
import { validate } from '../middleware/validate.js'
import { createProductSchema, updateProductSchema } from './products.schema.js'
import type { ProductsController } from './products.controller.js'
import { AppError } from '../errors.js'
import { config } from '../config.js'

export const createProductsRouter = (controller: ProductsController) => {
  const router = Router()

  const upload = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: config.MAX_FILE_SIZE_MB * 1024 * 1024 },
    fileFilter: (_req, file, cb) => {
      const allowed = ['image/jpeg', 'image/png', 'image/gif', 'image/webp']
      cb(null, allowed.includes(file.mimetype))
    },
  })

  const handleUpload = (req: Request, res: Response, next: NextFunction) => {
    upload.single('file')(req, res, (err) => {
      if (err instanceof MulterError) {
        next(new AppError(400, 'FILE_UPLOAD_ERROR', err.message))
      } else {
        next(err)
      }
    })
  }

  router.get('/',        controller.list)
  router.get('/:id',    controller.get)
  router.post('/',      validate(createProductSchema),  controller.create)
  router.put('/:id',    validate(updateProductSchema),  controller.update)
  router.delete('/:id', controller.remove)
  router.post('/:id/image', handleUpload, controller.uploadImage)

  return router
}
```

Router takes only `controller` — storage is encapsulated in controller.

---

**19. `backend/nodejs/src/app.ts`** — new

```typescript
import express from 'express'
import cors from 'cors'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { requestLogger } from './middleware/requestLogger.js'
import { errorHandler } from './middleware/errorHandler.js'
import { createProductsRouter } from './products/products.router.js'
import { config } from './config.js'
import { sql } from 'drizzle-orm'
import type { Db } from './db/client.js'
import type { ProductsController } from './products/products.controller.js'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

export const createApp = (db: Db, controller: ProductsController) => {
  const app = express()

  app.use(cors({ origin: config.CORS_ORIGIN }))
  app.use(express.json())
  app.use(requestLogger)
  app.use('/uploads', express.static(path.resolve(config.UPLOAD_DIR)))

  app.use('/api/v1/products', createProductsRouter(controller))

  app.get('/health', async (_req, res) => {
    let dbStatus = 'ok'
    try { await db.execute(sql`SELECT 1`) } catch { dbStatus = 'error' }
    res.json({ status: 'ok', uptime: process.uptime(), db: dbStatus })
  })

  app.use(errorHandler)
  return app
}
```

`createApp` takes `db` + `controller` only. Storage is inside controller.

---

**20. `backend/nodejs/src/index.ts`** — replaces `src/index.js`

```typescript
import 'dotenv/config'
import { config } from './config.js'
import { logger } from './logger.js'
import { db, closePool } from './db/client.js'
import { NoOpEventBus } from './events/event-bus.interface.js'
import { LocalDiskStorage } from './storage/local.storage.js'
import { ProductsService } from './products/products.service.js'
import { ProductsController } from './products/products.controller.js'
import { createApp } from './app.js'
import { sql } from 'drizzle-orm'

const eventBus   = new NoOpEventBus()
const storage    = new LocalDiskStorage()
const service    = new ProductsService(db, eventBus)
const controller = new ProductsController(service, storage)
const app        = createApp(db, controller)

await db.execute(sql`SELECT 1`)
logger.info('Database connected')

const server = app.listen(config.PORT, () => {
  logger.info({ port: config.PORT }, 'Server started')
})

const shutdown = async () => {
  logger.info('Shutting down')
  server.close(async () => {
    await closePool()
    process.exit(0)
  })
}

process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
```

---

**21. `backend/nodejs/Dockerfile`** — multi-stage

```dockerfile
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src/ ./src/
RUN npm run build

FROM node:22-alpine AS runner
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY --from=builder /app/dist ./dist
EXPOSE 3000
CMD ["node", "dist/index.js"]
```

`pino-pretty` is a devDependency — excluded from runner image. `NODE_ENV=production` → plain JSON logging.

---

**Files to delete (backend):**
- `backend/nodejs/src/index.js`
- `backend/nodejs/src/db.js`
- `backend/nodejs/src/routes/items.js`

---

## §8 Frontend Implementation Plan

Build order: package.json → tsconfig → vite.config → CSS → api → main → root route → pages → Dockerfile.

---

**1. `front/react/package.json`** — full replace

```json
{
  "name": "frontend-react",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "@tanstack/react-query": "^5.62.0",
    "@tanstack/react-router": "^1.93.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0"
  },
  "devDependencies": {
    "@tailwindcss/vite": "^4.0.0",
    "@tanstack/router-plugin": "^1.93.0",
    "@types/react": "^19.0.0",
    "@types/react-dom": "^19.0.0",
    "@vitejs/plugin-react": "^4.3.0",
    "tailwindcss": "^4.0.0",
    "typescript": "^5.7.0",
    "vite": "^6.0.0"
  }
}
```

⚠️ Verify `@tanstack/router-plugin` package name against npm at install time — has changed across minor versions. Fallback: `@tanstack/router-vite-plugin`.

---

**2. `front/react/tsconfig.json`** + **`tsconfig.node.json`** — new

```json
// tsconfig.json
{
  "compilerOptions": {
    "target": "ES2022", "lib": ["ES2022","DOM","DOM.Iterable"],
    "module": "ESNext", "moduleResolution": "Bundler",
    "jsx": "react-jsx", "strict": true, "noEmit": true,
    "esModuleInterop": true, "skipLibCheck": true,
    "allowImportingTsExtensions": true
  },
  "include": ["src"],
  "references": [{ "path": "./tsconfig.node.json" }]
}

// tsconfig.node.json
{
  "compilerOptions": {
    "composite": true, "module": "ESNext",
    "moduleResolution": "Bundler", "allowSyntheticDefaultImports": true
  },
  "include": ["vite.config.ts"]
}
```

---

**3. `front/react/vite.config.ts`** — replaces `vite.config.js`

```typescript
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { TanStackRouterVite } from '@tanstack/router-plugin/vite'

export default defineConfig({
  plugins: [TanStackRouterVite(), react(), tailwindcss()],
  server: {
    port: 5173,
    proxy: { '/api': { target: 'http://localhost:3000', changeOrigin: true } },
  },
})
```

`TanStackRouterVite()` must be first plugin.

---

**4. `front/react/.env.example`** — new

```
VITE_API_BASE_URL=http://localhost:3000/api/v1
```

Docker mode: set to `/api/v1` (nginx proxy handles host).

---

**5. `front/react/src/index.css`** — replace entire file

```css
@import "tailwindcss";
```

---

**6. `front/react/src/api/products.ts`** — new

```typescript
const BASE = import.meta.env['VITE_API_BASE_URL'] as string

export interface Product {
  id: number; name: string; description: string | null
  price: string; stock: number; image_path: string | null
  created_at: string; updated_at: string
}
export interface ProductListMeta  { total: number; page: number; limit: number }
export interface ProductListResponse { data: Product[]; meta: ProductListMeta }
export interface ProductResponse  { data: Product }
export interface CreateProductInput { name: string; description?: string | null; price: number; stock?: number }
export interface UpdateProductInput { name?: string; description?: string | null; price?: number; stock?: number }

const handleResponse = async <T>(res: Response): Promise<T> => {
  if (!res.ok) {
    const body = await res.json().catch(() => ({})) as { error?: { message?: string } }
    throw new Error(body?.error?.message ?? `HTTP ${res.status}`)
  }
  return res.json() as Promise<T>
}

export const fetchProducts = (page = 1, limit = 20) =>
  fetch(`${BASE}/products?page=${page}&limit=${limit}`).then(r => handleResponse<ProductListResponse>(r))

export const fetchProduct = (id: number) =>
  fetch(`${BASE}/products/${id}`).then(r => handleResponse<ProductResponse>(r))

export const createProduct = (input: CreateProductInput) =>
  fetch(`${BASE}/products`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input),
  }).then(r => handleResponse<ProductResponse>(r))

export const updateProduct = (id: number, input: UpdateProductInput) =>
  fetch(`${BASE}/products/${id}`, {
    method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input),
  }).then(r => handleResponse<ProductResponse>(r))

export const deleteProduct = (id: number) =>
  fetch(`${BASE}/products/${id}`, { method: 'DELETE' })
    .then(r => { if (!r.ok && r.status !== 204) throw new Error(`HTTP ${r.status}`) })
```

---

**7. `front/react/src/main.tsx`** — replaces `main.jsx`

```tsx
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { RouterProvider, createRouter } from '@tanstack/react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { routeTree } from './routeTree.gen'
import './index.css'

const queryClient = new QueryClient()
const router = createRouter({ routeTree })

declare module '@tanstack/react-router' {
  interface Register { router: typeof router }
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </StrictMode>,
)
```

`src/routeTree.gen.ts` is auto-generated on `npm run dev`. **Commit to repo** — avoids cold-CI failures.

---

**8. `front/react/src/routes/__root.tsx`** — new

```tsx
import { createRootRoute, Outlet, Link } from '@tanstack/react-router'

export const Route = createRootRoute({
  component: () => (
    <div className="min-h-screen bg-gray-50">
      <nav className="bg-slate-900 text-white px-6 py-4 flex justify-between items-center">
        <Link to="/" className="text-xl font-bold">Full Stack App</Link>
        <div className="flex gap-6">
          <Link to="/" className="hover:text-gray-300 [&.active]:text-white">Home</Link>
          <Link to="/products" className="hover:text-gray-300 [&.active]:text-white">Products</Link>
        </div>
      </nav>
      <main className="max-w-5xl mx-auto px-6 py-8"><Outlet /></main>
    </div>
  ),
})
```

---

**9. `front/react/src/routes/index.tsx`** — new (Home)

```tsx
import { createFileRoute, Link } from '@tanstack/react-router'

export const Route = createFileRoute('/')({
  component: () => (
    <div className="text-center py-16">
      <h1 className="text-4xl font-bold text-slate-900 mb-4">Full Stack Template</h1>
      <p className="text-lg text-gray-600 mb-8">Production-grade Node.js + React app.</p>
      <Link to="/products" className="bg-slate-900 text-white px-6 py-3 rounded hover:bg-slate-700">
        View Products
      </Link>
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mt-16 text-left">
        {[
          ['Backend', 'Express 5 · TypeScript · Drizzle ORM · Pino'],
          ['Frontend', 'React 19 · TanStack Router · TanStack Query · Tailwind v4'],
          ['Database', 'MySQL 8.4 · Drizzle Kit migrations · Docker'],
        ].map(([title, desc]) => (
          <div key={title} className="bg-white rounded-lg p-6 shadow-sm">
            <h2 className="font-semibold text-slate-900 mb-2">{title}</h2>
            <p className="text-gray-600 text-sm">{desc}</p>
          </div>
        ))}
      </div>
    </div>
  ),
})
```

---

**10. `front/react/src/routes/products/index.tsx`** — new (Product list)

```tsx
import { createFileRoute, Link, useNavigate } from '@tanstack/react-router'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { fetchProducts, deleteProduct } from '../../api/products'

export const Route = createFileRoute('/products/')({ component: ProductList })

function ProductList() {
  const qc = useQueryClient()
  const navigate = useNavigate()
  const { data, isLoading, error } = useQuery({
    queryKey: ['products'],
    queryFn: () => fetchProducts(),
  })
  const deleteMutation = useMutation({
    mutationFn: deleteProduct,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['products'] }),
  })

  if (isLoading) return <p className="text-gray-500">Loading...</p>
  if (error)     return <p className="text-red-600">Error: {(error as Error).message}</p>

  return (
    <div>
      <div className="flex justify-between items-center mb-6">
        <h1 className="text-2xl font-bold text-slate-900">Products</h1>
        <Link to="/products/create" className="bg-slate-900 text-white px-4 py-2 rounded text-sm hover:bg-slate-700">
          Add Product
        </Link>
      </div>
      {!data?.data.length ? (
        <p className="text-gray-400 text-center py-12">No products yet.</p>
      ) : (
        <div className="bg-white rounded-lg shadow-sm overflow-hidden">
          <table className="w-full text-sm">
            <thead className="bg-gray-50 text-gray-700">
              <tr>{['Name','Price','Stock','Actions'].map(h => <th key={h} className="px-4 py-3 text-left font-medium">{h}</th>)}</tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {data.data.map(p => (
                <tr key={p.id} className="hover:bg-gray-50 cursor-pointer"
                    onClick={() => navigate({ to: '/products/$id', params: { id: String(p.id) } })}>
                  <td className="px-4 py-3 font-medium">{p.name}</td>
                  <td className="px-4 py-3 text-gray-600">${p.price}</td>
                  <td className="px-4 py-3 text-gray-600">{p.stock}</td>
                  <td className="px-4 py-3" onClick={e => e.stopPropagation()}>
                    <Link to="/products/$id/edit" params={{ id: String(p.id) }}
                          className="text-blue-600 hover:underline mr-4 text-xs">Edit</Link>
                    <button onClick={() => confirm('Delete?') && deleteMutation.mutate(p.id)}
                            className="text-red-600 hover:underline text-xs">Delete</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {data?.meta && (
        <p className="text-xs text-gray-400 mt-4">
          {data.meta.total} total · page {data.meta.page} of {Math.ceil(data.meta.total / data.meta.limit)}
        </p>
      )}
    </div>
  )
}
```

---

**11. `front/react/src/routes/products/$id.tsx`** — new (Detail)

```tsx
import { createFileRoute, Link, useNavigate } from '@tanstack/react-router'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { fetchProduct, deleteProduct } from '../../api/products'

export const Route = createFileRoute('/products/$id')({ component: ProductDetail })

function ProductDetail() {
  const { id } = Route.useParams()
  const navigate = useNavigate()
  const qc = useQueryClient()
  const { data, isLoading, error } = useQuery({
    queryKey: ['products', id],
    queryFn: () => fetchProduct(Number(id)),
  })
  const deleteMutation = useMutation({
    mutationFn: () => deleteProduct(Number(id)),
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['products'] }); navigate({ to: '/products' }) },
  })

  if (isLoading) return <p className="text-gray-500">Loading...</p>
  if (error)     return <p className="text-red-600">Error: {(error as Error).message}</p>
  if (!data)     return <p className="text-red-600">Not found</p>

  const p = data.data
  return (
    <div>
      <Link to="/products" className="text-slate-600 hover:underline text-sm">← Back</Link>
      <div className="mt-4 bg-white rounded-lg shadow-sm p-6">
        <div className="flex justify-between items-start mb-4">
          <h1 className="text-2xl font-bold text-slate-900">{p.name}</h1>
          <div className="flex gap-2">
            <Link to="/products/$id/edit" params={{ id: String(p.id) }}
                  className="bg-amber-400 text-slate-900 px-3 py-1 rounded text-sm">Edit</Link>
            <button onClick={() => confirm('Delete?') && deleteMutation.mutate()}
                    className="bg-red-500 text-white px-3 py-1 rounded text-sm">Delete</button>
          </div>
        </div>
        {p.image_path && <img src={p.image_path} alt={p.name} className="w-48 h-48 object-cover rounded mb-4" />}
        <p className="text-gray-600 mb-4">{p.description ?? 'No description'}</p>
        <dl className="grid grid-cols-2 gap-2 text-sm">
          <dt className="text-gray-500">Price</dt><dd className="font-medium">${p.price}</dd>
          <dt className="text-gray-500">Stock</dt><dd className="font-medium">{p.stock}</dd>
          <dt className="text-gray-500">Created</dt><dd>{new Date(p.created_at).toLocaleString()}</dd>
          <dt className="text-gray-500">Updated</dt><dd>{new Date(p.updated_at).toLocaleString()}</dd>
        </dl>
      </div>
    </div>
  )
}
```

---

**12. `front/react/src/routes/products/create.tsx`** — new

```tsx
import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { createProduct } from '../../api/products'

export const Route = createFileRoute('/products/create')({ component: CreateProduct })

const inputCls = 'w-full border border-gray-300 rounded px-3 py-2 text-sm focus:outline-none focus:border-slate-500'
const labelCls = 'block text-sm font-medium text-gray-700 mb-1'

function CreateProduct() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [form, setForm] = useState({ name: '', description: '', price: '', stock: '0' })
  const [error, setError] = useState<string | null>(null)
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm(f => ({ ...f, [k]: e.target.value }))

  const mutation = useMutation({
    mutationFn: createProduct,
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['products'] }); navigate({ to: '/products' }) },
    onError: (e: Error) => setError(e.message),
  })

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault(); setError(null)
    mutation.mutate({ name: form.name, description: form.description || null, price: Number(form.price), stock: Number(form.stock) })
  }

  return (
    <div className="max-w-lg">
      <h1 className="text-2xl font-bold text-slate-900 mb-6">New Product</h1>
      {error && <p className="bg-red-50 text-red-700 p-3 rounded mb-4 text-sm">{error}</p>}
      <form onSubmit={handleSubmit} className="bg-white rounded-lg shadow-sm p-6 space-y-4">
        <div><label className={labelCls}>Name *</label><input required className={inputCls} value={form.name} onChange={set('name')} /></div>
        <div><label className={labelCls}>Description</label><textarea className={inputCls} rows={3} value={form.description} onChange={set('description')} /></div>
        <div><label className={labelCls}>Price *</label><input required type="number" min="0" step="0.01" className={inputCls} value={form.price} onChange={set('price')} /></div>
        <div><label className={labelCls}>Stock</label><input type="number" min="0" className={inputCls} value={form.stock} onChange={set('stock')} /></div>
        <button type="submit" disabled={mutation.isPending}
                className="w-full bg-slate-900 text-white py-2 rounded hover:bg-slate-700 disabled:opacity-50">
          {mutation.isPending ? 'Creating...' : 'Create Product'}
        </button>
      </form>
    </div>
  )
}
```

---

**13. `front/react/src/routes/products/$id.edit.tsx`** — new

```tsx
import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useState, useEffect } from 'react'
import { fetchProduct, updateProduct } from '../../api/products'

export const Route = createFileRoute('/products/$id/edit')({ component: EditProduct })

const inputCls = 'w-full border border-gray-300 rounded px-3 py-2 text-sm focus:outline-none focus:border-slate-500'
const labelCls = 'block text-sm font-medium text-gray-700 mb-1'

function EditProduct() {
  const { id } = Route.useParams()
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [form, setForm] = useState({ name: '', description: '', price: '', stock: '0' })
  const [error, setError] = useState<string | null>(null)
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm(f => ({ ...f, [k]: e.target.value }))

  const { data, isLoading } = useQuery({ queryKey: ['products', id], queryFn: () => fetchProduct(Number(id)) })

  useEffect(() => {
    if (data?.data) {
      const p = data.data
      setForm({ name: p.name, description: p.description ?? '', price: p.price, stock: String(p.stock) })
    }
  }, [data])

  const mutation = useMutation({
    mutationFn: (input: Parameters<typeof updateProduct>[1]) => updateProduct(Number(id), input),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['products'] })
      qc.invalidateQueries({ queryKey: ['products', id] })
      navigate({ to: '/products/$id', params: { id } })
    },
    onError: (e: Error) => setError(e.message),
  })

  if (isLoading) return <p className="text-gray-500">Loading...</p>

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault(); setError(null)
    mutation.mutate({ name: form.name, description: form.description || null, price: Number(form.price), stock: Number(form.stock) })
  }

  return (
    <div className="max-w-lg">
      <h1 className="text-2xl font-bold text-slate-900 mb-6">Edit Product</h1>
      {error && <p className="bg-red-50 text-red-700 p-3 rounded mb-4 text-sm">{error}</p>}
      <form onSubmit={handleSubmit} className="bg-white rounded-lg shadow-sm p-6 space-y-4">
        <div><label className={labelCls}>Name *</label><input required className={inputCls} value={form.name} onChange={set('name')} /></div>
        <div><label className={labelCls}>Description</label><textarea className={inputCls} rows={3} value={form.description} onChange={set('description')} /></div>
        <div><label className={labelCls}>Price *</label><input required type="number" min="0" step="0.01" className={inputCls} value={form.price} onChange={set('price')} /></div>
        <div><label className={labelCls}>Stock</label><input type="number" min="0" className={inputCls} value={form.stock} onChange={set('stock')} /></div>
        <div className="flex gap-3">
          <button type="submit" disabled={mutation.isPending}
                  className="flex-1 bg-slate-900 text-white py-2 rounded hover:bg-slate-700 disabled:opacity-50">
            {mutation.isPending ? 'Saving...' : 'Save Changes'}
          </button>
          <button type="button" onClick={() => navigate({ to: '/products/$id', params: { id } })}
                  className="flex-1 border border-gray-300 py-2 rounded hover:bg-gray-50">
            Cancel
          </button>
        </div>
      </form>
    </div>
  )
}
```

---

**14. `front/react/Dockerfile`** — multi-stage

```dockerfile
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:alpine AS runner
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

---

**15. `front/react/nginx.conf`** — new

```nginx
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;
    location / { try_files $uri $uri/ /index.html; }
    location /api {
        proxy_pass http://backend:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    location /uploads { proxy_pass http://backend:3000; }
}
```

---

**Files to delete (frontend):**
- `front/react/src/App.jsx`, `src/main.jsx`
- `front/react/src/pages/` (all)
- `front/react/src/components/AddItemForm.jsx`, `EditItemForm.jsx`
- `front/react/vite.config.js`

---

## §9–11 N/A

Real-time, distributed events, AI — not in scope.

---

## §12 Validation & Error Handling

- `validate(schema)` middleware: passes errors through `next(new AppError(400, 'VALIDATION_ERROR', ...))` → single response-shape writer (global handler)
- POST uses `createProductSchema`, PUT uses `updateProductSchema` (applied in router before controller)
- Query params parsed in controller via `paginationSchema.parse(req.query)`
- `MulterError` → wrapped to `AppError(400, 'FILE_UPLOAD_ERROR', ...)` in `handleUpload` wrapper in router
- Missing file: `controller.uploadImage` throws `AppError(400, 'FILE_UPLOAD_ERROR', 'No file provided')`

| Code | HTTP | Source |
|------|------|--------|
| `VALIDATION_ERROR` | 400 | Zod failure via middleware |
| `NOT_FOUND` | 404 | Service throws AppError |
| `FILE_UPLOAD_ERROR` | 400 | Multer error or missing file |
| `INTERNAL_ERROR` | 500 | Unhandled exception |

`AppError` → `warn` log. Unknown errors → `error` log with full stack.

---

## §13 Auth & Security Notes

- No auth (PRD non-goal).
- **MIME allowlist**: `['image/jpeg', 'image/png', 'image/gif', 'image/webp']` in multer fileFilter.
- **File size**: `MAX_FILE_SIZE_MB` bytes enforced by multer.
- **Filename**: UUID-generated server-side — no client filename used in path (prevents path traversal).
- **Parameterized queries**: Drizzle ORM — no raw SQL concatenation.
- **Secrets**: `DATABASE_URL` in `.env` (gitignored), not logged, not in client bundle.
- **Client bundle**: only `VITE_API_BASE_URL` — public API URL, no credentials.
- **CORS**: `cors({ origin: config.CORS_ORIGIN })` — defaults to `*`, tighten via env var.

---

## §14 Observability & Telemetry

**No OTEL SDK.** Pino structured logging only. `requestId` is the OTEL `traceId` placeholder.

**Log fields per line:** `{ level, time, service: "backend-nodejs", env, ...context }`

**Request log (on response finish):**
```json
{ "requestId": "uuid", "method": "GET", "url": "/api/v1/products", "statusCode": 200, "responseTimeMs": 12 }
```

**AppError log (warn):**
```json
{ "requestId": "uuid", "code": "NOT_FOUND", "msg": "Product not found" }
```

**Unhandled error log (error):**
```json
{ "requestId": "uuid", "err": { "message": "...", "stack": "..." }, "msg": "Unhandled error" }
```

**Startup logs:** `"Database connected"`, `{ "port": 3000, "msg": "Server started" }`.

**Dev**: pino-pretty. **Prod**: plain JSON (pino-pretty devDep, excluded from Docker runner).

**Health**: `GET /health` — `SELECT 1` via Drizzle. Returns `{ status, uptime, db: "ok"|"error" }`. Not versioned.

**OTEL upgrade path**: replace `randomUUID()` in requestLogger with OTEL context extraction. Add `trace_id`/`span_id` to log lines via OTEL log bridge.

**FE**: `console.error` for caught errors only.

---

## §15 Infra & Deployment Notes

### Env vars

**Backend (`.env.example`):**

| Var | Required | Default | Example |
|-----|----------|---------|---------|
| `PORT` | No | 3000 | `3000` |
| `DATABASE_URL` | **Yes** | — | `mysql://template_user:template_pass@localhost:3306/template_db` |
| `UPLOAD_DIR` | No | `./uploads` | `./uploads` |
| `MAX_FILE_SIZE_MB` | No | 10 | `10` |
| `NODE_ENV` | No | `development` | `production` |
| `CORS_ORIGIN` | No | `*` | `https://app.example.com` |

**Frontend (`.env.example`):**

| Var | Required | Example |
|-----|----------|---------|
| `VITE_API_BASE_URL` | **Yes** | `http://localhost:3000/api/v1` |

### `docker-compose.yml` — full stack

```yaml
services:
  db:
    image: mysql:8.4
    container_name: template-db
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: template_db
      MYSQL_USER: template_user
      MYSQL_PASSWORD: template_pass
    ports:
      - "3306:3306"
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-prootpassword"]
      interval: 10s
      timeout: 5s
      retries: 5

  backend:
    build: ./backend/nodejs
    container_name: template-backend
    environment:
      PORT: 3000
      DATABASE_URL: mysql://template_user:template_pass@db:3306/template_db
      UPLOAD_DIR: ./uploads
      MAX_FILE_SIZE_MB: 10
      NODE_ENV: production
      CORS_ORIGIN: "*"
    ports:
      - "3000:3000"
    volumes:
      - uploads_data:/app/uploads
    depends_on:
      db:
        condition: service_healthy

  frontend:
    build: ./front/react
    container_name: template-frontend
    ports:
      - "80:80"
    depends_on:
      - backend

volumes:
  db_data:
  uploads_data:
```

⚠️ No initdb.d mounts. manage.sh runs migrations (`node dist/migrate.js` in container) and seed (`docker compose exec -T db mysql ...`) after DB healthcheck.

### `docker-compose.dev.yml` — DB only (new at repo root)

```yaml
services:
  db:
    image: mysql:8.4
    container_name: template-db
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: template_db
      MYSQL_USER: template_user
      MYSQL_PASSWORD: template_pass
    ports:
      - "3306:3306"
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-prootpassword"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  db_data:
```

No initdb.d mounts. Neither migrations nor seed are mounted — both applied via manage.sh post-healthcheck.

### `manage.sh` — replaces `deploy.sh`

**Prerequisites (checked on startup):** `node`, `npm`, `docker`, `docker compose`, `mysql` (client, for seed command).

Key behaviors vs current `deploy.sh`:
- `start native`: start DB (`docker-compose.dev.yml`) → wait healthcheck → `cd backend/nodejs && npm run db:migrate` → `mysql -utemplate_user -ptemplate_pass -h 127.0.0.1 template_db < db/mysql/seed/seed.sql` → start backend + frontend via `npm run dev` (tsx watch) → store PIDs in `.pids/`
- `start docker`: `docker compose up -d --build` → wait DB healthcheck → `docker compose exec backend node dist/migrate.js` → `docker compose exec -T db mysql -utemplate_user -ptemplate_pass template_db < db/mysql/seed/seed.sql`
- `stop native`: kill PIDs from `.pids/`, `docker compose -f docker-compose.dev.yml down`
- `stop docker`: `docker compose down`
- `status`: show running services + PIDs
- `logs [backend|frontend|db|all]`: tail logs
- `rebuild`: stop → reinstall deps → start
- `reset-db native`: `docker compose -f docker-compose.dev.yml down -v` → start native
- `reset-db docker`: `docker compose down -v db` → `docker compose up -d db` → wait healthcheck → migrate
- Prereq check on every invocation: `node`, `npm`, `docker`, `docker compose`
- PIDs stored in `.pids/backend.pid` and `.pids/frontend.pid`

### Migrations flow

| Mode | Tool | When |
|------|------|------|
| Native dev | `npm run db:migrate` (drizzle-kit, devDep) | `manage.sh start native` after DB healthcheck |
| Docker | `docker compose exec backend node dist/migrate.js` (programmatic, no drizzle-kit) | `manage.sh start docker` after DB healthcheck |
| Generate new migration | `npm run db:generate` (from `backend/nodejs/`) | After editing `src/db/schema/products.ts` |

**Drizzle tracks ledger** in `__drizzle_migrations` table in `template_db`. Single source of truth in both environments.

**Delete:** `db/mysql/docker-compose.yml`

---

## §16 Side-Effect Sweep (Gate D)

| Item | Answer | Notes |
|------|--------|-------|
| New table? | ✅ Yes | `products` — Drizzle-generated migration. Fresh DB. |
| NOT NULL backfill? | N/A | Fresh table. |
| FK added? | No | No relations. |
| Soft delete? | No | Hard delete. |
| N+1 risk? | No | Single SELECT + LIMIT/OFFSET. Two parallel queries (rows + count). |
| Transaction boundary? | No | Single-table ops. |
| Breaking API? | ✅ Yes | `/api/items` → `/api/v1/products`. Frontend rebuilt simultaneously. No external consumers. |
| Pagination envelope? | ✅ Yes | `{data, meta: {total, page, limit}}` |
| Idempotency key? | No | Study project. |
| File upload MIME allowlist? | ✅ Yes | jpeg, png, gif, webp. |
| File size limit? | ✅ Yes | `MAX_FILE_SIZE_MB`. |
| MulterError handled? | ✅ Yes | Converted to AppError(400) in `handleUpload` wrapper. |
| Filename path traversal? | ✅ Yes | Server-generated UUID filename; client name used for extension only. |
| Rate limit? | N/A | Out of scope. |
| Outbox/consumer? | N/A | NoOpEventBus. |
| New route registration? | ✅ Yes | TanStack Router Vite plugin auto-generates `routeTree.gen.ts`. Committed to repo. |
| Query cache invalidation? | ✅ Yes | Create/Delete → `['products']`. Update → `['products']` + `['products', id]`. |
| Optimistic update? | No | Mutations await server. |
| SSR secrets? | ✅ Yes | Only `VITE_*` in bundle. DB creds never exposed. |
| requestId in logs? | ✅ Yes | Every request log line. |
| requestId propagated? | ✅ Yes | `X-Request-Id` response header. |
| PII in logs? | ✅ Verified | No user data, no credentials logged. |
| Graceful shutdown? | ✅ Yes | SIGTERM closes HTTP server + DB pool. |
| Dual migration paths? | ✅ Resolved | Drizzle Kit only. No initdb.d migration mount. |

---

## §17 Compatibility & Rollout Sweep (Gate F)

| Item | Answer | Mitigation |
|------|--------|------------|
| Existing clients break? | N/A | No external consumers. Frontend rebuilt simultaneously. |
| Versioning conflict? | N/A | New `/api/v1/` replaces `/api/items`. |
| Migration destructive? | Yes | Fresh DB. `manage.sh reset-db` drops volume. |
| Down-migration? | ✅ Yes | `DROP TABLE IF EXISTS products;` — in §6, not wired into tooling. |
| Long-running DDL? | N/A | Fresh table, no data. |
| Feature flag? | No | Study project. |
| Routes public? | ✅ Yes | No auth. |
| Code rollback safe? | ✅ Yes | `manage.sh reset-db` documented. |

---

## §18 Seed Data

**File:** `db/mysql/seed/seed.sql` — idempotent, inserts only if table empty.

```sql
INSERT INTO products (name, description, price, stock)
WITH seed AS (
  SELECT 'Running Shoes'       name, 'Lightweight trail running shoes, breathable mesh upper'  description, 89.99  price, 50 stock UNION ALL
  SELECT 'Wireless Headphones',      'Active noise cancellation, 30hr battery, USB-C charging',            199.99,       25        UNION ALL
  SELECT 'Coffee Maker',             'Programmable 12-cup drip coffee maker with thermal carafe',           79.99,       30        UNION ALL
  SELECT 'Yoga Mat',                 'Non-slip 6mm thick TPE mat, includes carry strap',                    34.99,       75        UNION ALL
  SELECT 'Mechanical Keyboard',      'Tenkeyless, tactile switches, RGB backlight, PBT keycaps',          129.99,       40        UNION ALL
  SELECT 'Stainless Water Bottle',   'Insulated 32oz, keeps cold 24h hot 12h, leak-proof lid',             24.99,      100        UNION ALL
  SELECT 'Desk Lamp',                'LED, adjustable color temp and brightness, USB charging port',        49.99,       60        UNION ALL
  SELECT 'Backpack',                 '30L travel backpack, laptop sleeve, water-resistant nylon',           59.99,       35        UNION ALL
  SELECT 'Bluetooth Speaker',        'Waterproof IPX7, 360 sound, 12hr playtime',                          69.99,       45        UNION ALL
  SELECT 'Standing Desk Mat',        'Anti-fatigue foam 30x20in, beveled edges, easy clean',               39.99,       55
)
SELECT name, description, price, stock FROM seed
WHERE (SELECT COUNT(*) FROM products) = 0;
```

Run by manage.sh after `db:migrate` in both modes. Not mounted in initdb.d.

---

## §19 Verification Steps

### Prerequisites
- Docker running, ports 3306, 3000, 5173 free
- `node --version` → v22.x, `npm --version` → 10.x, `docker compose version` → v2.x

### Golden path — native dev

```bash
./manage.sh start native
# Expect: DB starts → migration runs → backend + frontend start

curl http://localhost:3000/health
# Expect: {"status":"ok","uptime":...,"db":"ok"}

curl http://localhost:3000/api/v1/products
# Expect: {"data":[...10...],"meta":{"total":10,"page":1,"limit":20}}

# CRUD
curl -X POST http://localhost:3000/api/v1/products \
  -H 'Content-Type: application/json' \
  -d '{"name":"Test Widget","price":9.99,"stock":5}'
# Expect: 201 {"data":{"id":11,...}}

curl -X PUT http://localhost:3000/api/v1/products/11 \
  -H 'Content-Type: application/json' -d '{"price":14.99}'
# Expect: 200, price "14.99"

curl -X DELETE http://localhost:3000/api/v1/products/11
# Expect: 204

curl http://localhost:3000/api/v1/products/11
# Expect: 404 {"error":{"code":"NOT_FOUND",...}}

# Image upload
curl -X POST http://localhost:3000/api/v1/products/1/image -F 'file=@image.jpg'
# Expect: 200, image_path set to /uploads/<uuid>.jpg

# X-Request-Id
curl -I http://localhost:3000/api/v1/products | grep X-Request-Id
# Expect: X-Request-Id: <uuid>
```

### Frontend checks (http://localhost:5173)

- `/` — Home renders, "View Products" link works
- `/products` — table with 10 rows, Name/Price/Stock columns
- Click row → `/products/1` — detail page, all fields
- "Edit" → `/products/1/edit` — form pre-populated; save → back to detail; query cache updated
- "Add Product" → `/products/create` — submit → redirect to list; count increments
- Delete on list row → confirm dialog → row removed, list refetches
- If `image_path` set on detail: `<img>` renders
- `description: ""` on create/edit → server stores null → detail shows "No description"

### Error paths

```bash
# Validation
curl -X POST http://localhost:3000/api/v1/products \
  -H 'Content-Type: application/json' -d '{"description":"no name"}'
# Expect: 400 {"error":{"code":"VALIDATION_ERROR",...}}

# Not found
curl http://localhost:3000/api/v1/products/99999
# Expect: 404 {"error":{"code":"NOT_FOUND",...}}

# Invalid MIME
curl -X POST http://localhost:3000/api/v1/products/1/image -F 'file=@doc.pdf'
# Expect: 400 {"error":{"code":"FILE_UPLOAD_ERROR",...}}

# DB down → health
# Stop DB, then:
curl http://localhost:3000/health
# Expect: {"status":"ok","db":"error"} — NOT 500
```

### Docker

```bash
./manage.sh start docker
docker compose ps  # all healthy
curl http://localhost:3000/health
curl http://localhost/  # nginx SPA
curl http://localhost/api/v1/products  # nginx → backend proxy
```

### TypeScript

```bash
cd backend/nodejs && npm run build      # zero errors
cd front/react && npx tsc --noEmit     # zero errors
```

### Migration ledger

```bash
mysql -u template_user -ptemplate_pass -h 127.0.0.1 template_db \
  -e "SELECT * FROM __drizzle_migrations;"
# Expect: one row for the products migration
```

---

## §20 Risk Summary & Open Questions

| Risk | Breaking? | Data-loss? | Perf? | Severity | Mitigation |
|------|-----------|-----------|-------|----------|------------|
| `items` table gone, `products` created | Yes (API) | Seed data only | None | Low | Fresh DB. `manage.sh reset-db` drops volume. Seed idempotent. |
| `@types/express` v5 type gaps | No | No | None | Low | `skipLibCheck: true`. Pin exact minor. |
| TanStack Router plugin package name | No | No | None | Low | Verify at install time. Fallback: `@tanstack/router-vite-plugin`. |
| Drizzle generates non-`V001__` filenames | No | No | None | Low | Drizzle Kit names like `0001_xxx.sql`. Flyway swap = rename files. Document this. |
| `pino-pretty` absent in Docker runner | No | No | None | Low | `npm ci --omit=dev`. `NODE_ENV=production` → plain JSON. |
| `price` as string in JSON | No | No | None | Low | Typed as `string` in frontend. Displayed with `$` prefix. |
| `manage.sh start docker` migrate race | No | No | None | Low | Wait for backend healthy before running migrate command. Use `docker exec` after `depends_on: service_healthy`. |

### Open questions

1. **`routeTree.gen.ts` git policy**: Commit to repo. Document: auto-regenerated by `vite dev`, do not hand-edit. Add note in `.gitignore` if any glob accidentally excludes `.gen.ts` files.
2. **Drizzle Kit filename convention vs Flyway**: Drizzle generates `0001_xxx.sql` format. PRD mentions Flyway-compatible `V001__` naming as a future swap point. When swapping to Flyway: rename files to `V001__xxx.sql` format. No code changes needed — Flyway reads the SQL directly.
3. **Seed execution requires mysql-client on host**: manage.sh runs `mysql -utemplate_user ...` for native mode. Docker mode uses `docker compose exec -T db mysql ...` (no host mysql-client needed). Document mysql-client as a prerequisite in manage.sh help text and README for native dev mode only.
