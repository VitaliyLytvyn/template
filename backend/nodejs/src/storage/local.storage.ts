import { promises as fs } from 'node:fs'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { config } from '../config.js'
import type { StorageProvider } from './storage.interface.js'

export class LocalDiskStorage implements StorageProvider {
  private readonly dir = path.resolve(config.UPLOAD_DIR)

  async save(file: Buffer, originalName: string, _mimetype: string): Promise<string> {
    await fs.mkdir(this.dir, { recursive: true })
    const ext = path.extname(originalName)
    const filename = `${randomUUID()}${ext}`
    await fs.writeFile(path.join(this.dir, filename), file)
    return `/uploads/${filename}`
  }

  async delete(filePath: string): Promise<void> {
    await fs.unlink(path.join(this.dir, path.basename(filePath))).catch(() => undefined)
  }

  getUrl(filePath: string): string {
    return filePath
  }
}
