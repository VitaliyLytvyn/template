import 'dotenv/config'
import { sdk } from './instrumentation.js'
import { config } from './config.js'
import { logger } from './logger.js'
import { db, closePool, pool } from './db/client.js'
import { dbPoolActive, dbPoolIdle } from './middleware/metrics.js'
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

// mysql2 pool internals — not public API; null-safe with warning fallback.
const poolInternals = (pool as unknown as {
  pool?: { _allConnections?: unknown[]; _freeConnections?: unknown[] }
}).pool

let dbGaugeInterval: ReturnType<typeof setInterval> | null = null

if (poolInternals?._allConnections !== undefined) {
  dbGaugeInterval = setInterval(() => {
    const total = poolInternals._allConnections?.length ?? 0
    const free  = poolInternals._freeConnections?.length ?? 0
    dbPoolActive.set(total - free)
    dbPoolIdle.set(free)
  }, 5000)
} else {
  logger.warn('mysql2 pool internals unavailable — db_pool_connections gauges will not be populated')
}

const shutdown = async () => {
  logger.info('Shutting down')

  if (dbGaugeInterval) clearInterval(dbGaugeInterval)

  await new Promise<void>((resolve) => {
    server.close(() => resolve())
    server.closeAllConnections()
  })

  await Promise.race([
    (async () => {
      await closePool()
      await sdk.shutdown()
    })(),
    new Promise<void>((_, reject) =>
      setTimeout(() => reject(new Error('Shutdown timeout')), 8000)
    ),
  ]).catch((err) => logger.error({ err }, 'Shutdown error — forcing exit'))

  process.exit(0)
}

process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
