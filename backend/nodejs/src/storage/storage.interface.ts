export interface StorageProvider {
  save(file: Buffer, filename: string, mimetype: string): Promise<string>
  delete(path: string): Promise<void>
  getUrl(path: string): string
}
