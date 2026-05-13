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
