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
