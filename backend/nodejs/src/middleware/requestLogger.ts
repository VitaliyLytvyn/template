import { randomUUID } from 'node:crypto'
import type { RequestHandler } from 'express'
import { logger } from '../logger.js'
import { httpRequestDuration, httpRequestTotal } from './metrics.js'

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

    const route = req.route
      ? `${req.baseUrl}${req.route.path as string}`
      : 'unmatched'
    const durationSec = (Date.now() - start) / 1000
    httpRequestDuration.observe(
      { method: req.method, route, status_code: String(res.statusCode) },
      durationSec,
    )
    httpRequestTotal.inc({ method: req.method, route, status_code: String(res.statusCode) })
  })
  next()
}
