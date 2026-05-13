const BASE: string = import.meta.env['VITE_API_BASE_URL'] ?? '/api/v1'

export interface Product {
  id: number; name: string; description: string | null
  price: string; stock: number; image_path: string | null
  created_at: string; updated_at: string
}
export interface ProductListMeta  { total: number; page: number; limit: number }
export interface ProductListResponse { data: Product[]; meta: ProductListMeta }
export interface ProductResponse  { data: Product }
export interface CreateProductInput { name: string; description?: string | null; price: number; stock?: number }
export interface UpdateProductInput { name?: string; description?: string | null; price?: number; stock?: number }

const handleResponse = async <T>(res: Response): Promise<T> => {
  if (!res.ok) {
    const body = await res.json().catch(() => ({})) as { error?: { message?: string } }
    throw new Error(body?.error?.message ?? `HTTP ${res.status}`)
  }
  return res.json() as Promise<T>
}

export const fetchProducts = (page = 1, limit = 20) =>
  fetch(`${BASE}/products?page=${page}&limit=${limit}`).then(r => handleResponse<ProductListResponse>(r))

export const fetchProduct = (id: number) =>
  fetch(`${BASE}/products/${id}`).then(r => handleResponse<ProductResponse>(r))

export const createProduct = (input: CreateProductInput) =>
  fetch(`${BASE}/products`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input),
  }).then(r => handleResponse<ProductResponse>(r))

export const updateProduct = (id: number, input: UpdateProductInput) =>
  fetch(`${BASE}/products/${id}`, {
    method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input),
  }).then(r => handleResponse<ProductResponse>(r))

export const deleteProduct = (id: number) =>
  fetch(`${BASE}/products/${id}`, { method: 'DELETE' })
    .then(r => { if (!r.ok && r.status !== 204) throw new Error(`HTTP ${r.status}`) })
