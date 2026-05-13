import { eq, count } from 'drizzle-orm'
import { products } from '../db/schema/products.js'
import type { Db } from '../db/client.js'
import type { DomainEventBus } from '../events/event-bus.interface.js'
import type { CreateProductInput, PaginationInput, UpdateProductInput } from './products.schema.js'
import { AppError } from '../errors.js'

export class ProductsService {
  constructor(private readonly db: Db, private readonly eventBus: DomainEventBus) {}

  async list({ page, limit }: PaginationInput) {
    const offset = (page - 1) * limit
    const [rows, [{ total }]] = await Promise.all([
      this.db.select().from(products).limit(limit).offset(offset),
      this.db.select({ total: count() }).from(products),
    ])
    return { rows, total: Number(total) }
  }

  async findById(id: number) {
    const [row] = await this.db.select().from(products).where(eq(products.id, id))
    if (!row) throw new AppError(404, 'NOT_FOUND', 'Product not found')
    return row
  }

  async create(dto: CreateProductInput) {
    const [result] = await this.db.insert(products).values({ ...dto, price: String(dto.price) })
    const created = await this.findById(result.insertId)
    await this.eventBus.publish({ type: 'product.created', payload: { id: created.id }, occurredAt: new Date() })
    return created
  }

  async update(id: number, dto: UpdateProductInput) {
    await this.findById(id)
    const { price, ...rest } = dto
    const patch = price !== undefined ? { ...rest, price: String(price) } : rest
    await this.db.update(products).set(patch).where(eq(products.id, id))
    const updated = await this.findById(id)
    await this.eventBus.publish({ type: 'product.updated', payload: { id }, occurredAt: new Date() })
    return updated
  }

  async delete(id: number) {
    await this.findById(id)
    await this.db.delete(products).where(eq(products.id, id))
    await this.eventBus.publish({ type: 'product.deleted', payload: { id }, occurredAt: new Date() })
  }

  async setImage(id: number, imagePath: string) {
    await this.findById(id)
    await this.db.update(products).set({ image_path: imagePath }).where(eq(products.id, id))
    return this.findById(id)
  }
}
