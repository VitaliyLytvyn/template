import { mysqlTable, int, varchar, text, decimal, datetime } from 'drizzle-orm/mysql-core'
import { sql } from 'drizzle-orm'

export const products = mysqlTable('products', {
  id:          int('id').primaryKey().autoincrement(),
  name:        varchar('name', { length: 255 }).notNull(),
  description: text('description'),
  price:       decimal('price', { precision: 10, scale: 2 }).notNull(),
  stock:       int('stock').notNull().default(0),
  image_path:  varchar('image_path', { length: 500 }),
  created_at:  datetime('created_at').notNull().default(sql`CURRENT_TIMESTAMP`),
  updated_at:  datetime('updated_at').default(sql`CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP`),
})

export type Product = typeof products.$inferSelect
export type NewProduct = typeof products.$inferInsert
