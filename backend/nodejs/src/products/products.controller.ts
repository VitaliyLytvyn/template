import type { Request, Response, NextFunction } from 'express'
import type { ProductsService } from './products.service.js'
import type { StorageProvider } from '../storage/storage.interface.js'
import { paginationSchema } from './products.schema.js'
import { AppError } from '../errors.js'

export class ProductsController {
  constructor(
    private readonly service: ProductsService,
    private readonly storage: StorageProvider,
  ) {}

  list = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const { page, limit } = paginationSchema.parse(req.query)
      const { rows, total } = await this.service.list({ page, limit })
      res.json({ data: rows, meta: { total, page, limit } })
    } catch (err) { next(err) }
  }

  get = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const product = await this.service.findById(Number(req.params['id']))
      res.json({ data: product })
    } catch (err) { next(err) }
  }

  create = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const product = await this.service.create(req.body)
      res.status(201).json({ data: product })
    } catch (err) { next(err) }
  }

  update = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const product = await this.service.update(Number(req.params['id']), req.body)
      res.json({ data: product })
    } catch (err) { next(err) }
  }

  remove = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      await this.service.delete(Number(req.params['id']))
      res.status(204).end()
    } catch (err) { next(err) }
  }

  uploadImage = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      if (!req.file) throw new AppError(400, 'FILE_UPLOAD_ERROR', 'No file provided')
      const imagePath = await this.storage.save(req.file.buffer, req.file.originalname, req.file.mimetype)
      const product = await this.service.setImage(Number(req.params['id']), imagePath)
      res.json({ data: product })
    } catch (err) { next(err) }
  }
}
