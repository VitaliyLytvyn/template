import { drizzle } from 'drizzle-orm/mysql2'
import mysql from 'mysql2/promise'
import { config } from '../config.js'
import * as schema from './schema/products.js'

const pool = mysql.createPool(config.DATABASE_URL)
export const db = drizzle(pool, { schema, mode: 'default' })
export type Db = typeof db

export const closePool = () => pool.end()
export { pool }
