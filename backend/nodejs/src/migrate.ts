import 'dotenv/config'
import { migrate } from 'drizzle-orm/mysql2/migrator'
import { db, closePool } from './db/client.js'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

const migrationsFolder = process.env['MIGRATIONS_DIR']
  ?? path.resolve(__dirname, '../../db/mysql/migrations')
await migrate(db, { migrationsFolder })
console.log('Migrations applied')
await closePool()
