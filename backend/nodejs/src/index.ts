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
