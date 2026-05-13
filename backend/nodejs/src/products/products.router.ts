import { Router } from 'express'
import multer, { MulterError } from 'multer'
import type { Request, Response, NextFunction } from 'express'
import { validate } from '../middleware/validate.js'
import { createProductSchema, updateProductSchema } from './products.schema.js'
import type { ProductsController } from './products.controller.js'
import { AppError } from '../errors.js'
import { config } from '../config.js'

export const createProductsRouter = (controller: ProductsController) => {
  const router = Router()

  const upload = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: config.MAX_FILE_SIZE_MB * 1024 * 1024 },
    fileFilter: (_req, file, cb) => {
      const allowed = ['image/jpeg', 'image/png', 'image/gif', 'image/webp']
      cb(null, allowed.includes(file.mimetype))
    },
  })

  const handleUpload = (req: Request, res: Response, next: NextFunction) => {
    upload.single('file')(req, res, (err) => {
      if (err instanceof MulterError) {
        next(new AppError(400, 'FILE_UPLOAD_ERROR', err.message))
      } else {
        next(err)
      }
    })
  }

  router.get('/',        controller.list)
  router.get('/:id',    controller.get)
  router.post('/',      validate(createProductSchema),  controller.create)
  router.put('/:id',    validate(updateProductSchema),  controller.update)
  router.delete('/:id', controller.remove)
  router.post('/:id/image', handleUpload, controller.uploadImage)

  return router
}
