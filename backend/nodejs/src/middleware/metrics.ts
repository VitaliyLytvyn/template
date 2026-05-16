import { register, collectDefaultMetrics, Histogram, Counter, Gauge } from 'prom-client'
import type { RequestHandler } from 'express'

collectDefaultMetrics()

export const httpRequestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request latency',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
})

export const httpRequestTotal = new Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
})

export const dbPoolActive = new Gauge({ name: 'db_pool_connections_active', help: 'Active DB pool connections' })
export const dbPoolIdle   = new Gauge({ name: 'db_pool_connections_idle',   help: 'Idle DB pool connections' })

export const metricsHandler: RequestHandler = async (_req, res) => {
  res.set('Content-Type', register.contentType)
  res.end(await register.metrics())
}
