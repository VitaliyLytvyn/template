import { z } from 'zod'

const envSchema = z.object({
  PORT:             z.string().default('3000').transform(Number),
  DATABASE_URL:     z.string().min(1),
  UPLOAD_DIR:       z.string().default('./uploads'),
  MAX_FILE_SIZE_MB: z.string().default('10').transform(Number),
  NODE_ENV:         z.enum(['development', 'production', 'test']).default('development'),
  CORS_ORIGIN:      z.string().default('*'),
})

export const config = envSchema.parse(process.env)
