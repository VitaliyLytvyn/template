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
