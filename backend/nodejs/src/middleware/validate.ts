import type { RequestHandler, NextFunction, Request, Response } from 'express'
import type { ZodSchema } from 'zod'
import { AppError } from '../errors.js'

export const validate = (schema: ZodSchema, target: 'body' | 'query' = 'body'): RequestHandler =>
  (req: Request, res: Response, next: NextFunction) => {
    const result = schema.safeParse(req[target])
    if (!result.success) {
      next(new AppError(400, 'VALIDATION_ERROR', result.error.message))
      return
    }
    req[target] = result.data
    next()
  }
