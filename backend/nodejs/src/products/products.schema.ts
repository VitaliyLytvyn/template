import { z } from 'zod'

const nullishString = z.string().nullish().transform(v => (v === '' ? null : v ?? null))

export const createProductSchema = z.object({
  name:        z.string().min(1).max(255),
  description: nullishString,
  price:       z.number().nonnegative(),
  stock:       z.number().int().nonnegative().optional().default(0),
})

export const updateProductSchema = createProductSchema.partial()

export const paginationSchema = z.object({
  page:  z.coerce.number().int().positive().optional().default(1),
  limit: z.coerce.number().int().positive().max(100).optional().default(20),
})

export type CreateProductInput = z.infer<typeof createProductSchema>
export type UpdateProductInput = z.infer<typeof updateProductSchema>
export type PaginationInput   = z.infer<typeof paginationSchema>
