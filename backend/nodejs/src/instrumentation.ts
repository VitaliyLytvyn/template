import 'dotenv/config'
import { NodeSDK } from '@opentelemetry/sdk-node'
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http'
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node'
import { Resource } from '@opentelemetry/resources'
import { SEMRESATTRS_SERVICE_NAME } from '@opentelemetry/semantic-conventions'
import { BatchSpanProcessor } from '@opentelemetry/sdk-trace-node'
import { diag, DiagConsoleLogger, DiagLogLevel } from '@opentelemetry/api'

diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.WARN)

// Intentionally bypass config.ts — Zod not bootstrapped at preload time.
// Defaults must stay in sync with config.ts defaults.
const endpoint = process.env['OTEL_EXPORTER_OTLP_TRACES_ENDPOINT'] ?? 'http://localhost:4318/v1/traces'
const serviceName = process.env['OTEL_SERVICE_NAME'] ?? 'backend-nodejs'

const exporter = new OTLPTraceExporter({ url: endpoint })

export const sdk = new NodeSDK({
  resource: new Resource({
    [SEMRESATTRS_SERVICE_NAME]: serviceName,
  }),
  spanProcessor: new BatchSpanProcessor(exporter, {
    maxQueueSize: 2048,
    maxExportBatchSize: 64,
    scheduledDelayMillis: 500,
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': { enabled: false },
      '@opentelemetry/instrumentation-dns': { enabled: false },
      '@opentelemetry/instrumentation-net': { enabled: false },
      '@opentelemetry/instrumentation-undici': { enabled: false },
      '@opentelemetry/instrumentation-winston': { enabled: false },
      '@opentelemetry/instrumentation-bunyan': { enabled: false },
      '@opentelemetry/instrumentation-connect': { enabled: false },
      '@opentelemetry/instrumentation-hapi': { enabled: false },
      '@opentelemetry/instrumentation-koa': { enabled: false },
      '@opentelemetry/instrumentation-fastify': { enabled: false },
      '@opentelemetry/instrumentation-restify': { enabled: false },
      '@opentelemetry/instrumentation-pg': { enabled: false },
      '@opentelemetry/instrumentation-mongodb': { enabled: false },
      '@opentelemetry/instrumentation-redis': { enabled: false },
      '@opentelemetry/instrumentation-redis-4': { enabled: false },
      '@opentelemetry/instrumentation-ioredis': { enabled: false },
      '@opentelemetry/instrumentation-graphql': { enabled: false },
      '@opentelemetry/instrumentation-grpc': { enabled: false },
    }),
  ],
})

sdk.start()
// Shutdown handled by index.ts in ordered sequence — do NOT add SIGTERM handler here.
