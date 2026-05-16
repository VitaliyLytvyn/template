import { z } from 'zod'

const envSchema = z.object({
  PORT:             z.string().default('3000').transform(Number),
  DATABASE_URL:     z.string().min(1),
  UPLOAD_DIR:       z.string().default('./uploads'),
  MAX_FILE_SIZE_MB: z.string().default('10').transform(Number),
  NODE_ENV:         z.enum(['development', 'production', 'test']).default('development'),
  CORS_ORIGIN:      z.string().default('*'),
  // Cross-reference: also read by instrumentation.ts (OTEL preload — bypasses Zod by design).
  // Defaults here must stay in sync with defaults in instrumentation.ts.
  OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: z.string().default('http://localhost:4318/v1/traces'),
  OTEL_SERVICE_NAME: z.string().default('backend-nodejs'),
})

export const config = envSchema.parse(process.env)
