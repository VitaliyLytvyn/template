import type { Config } from 'drizzle-kit'

export default {
  schema: './src/db/schema/*.ts',
  out: '../../db/mysql/migrations',
  dialect: 'mysql',
  dbCredentials: { url: process.env['DATABASE_URL']! },
} satisfies Config
