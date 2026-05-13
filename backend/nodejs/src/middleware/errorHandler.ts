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
