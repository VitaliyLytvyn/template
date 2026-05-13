import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useState, useEffect } from 'react'
import { fetchProduct, updateProduct } from '../../api/products'

export const Route = createFileRoute('/products/$id/edit')({ component: EditProduct })

const inputCls = 'w-full border border-gray-300 rounded px-3 py-2 text-sm focus:outline-none focus:border-slate-500'
const labelCls = 'block text-sm font-medium text-gray-700 mb-1'

function EditProduct() {
  const { id } = Route.useParams()
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [form, setForm] = useState({ name: '', description: '', price: '', stock: '0' })
  const [error, setError] = useState<string | null>(null)
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm(f => ({ ...f, [k]: e.target.value }))

  const { data, isLoading } = useQuery({ queryKey: ['products', id], queryFn: () => fetchProduct(Number(id)) })

  useEffect(() => {
    if (data?.data) {
      const p = data.data
      setForm({ name: p.name, description: p.description ?? '', price: p.price, stock: String(p.stock) })
    }
  }, [data])

  const mutation = useMutation({
    mutationFn: (input: Parameters<typeof updateProduct>[1]) => updateProduct(Number(id), input),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['products'] })
      qc.invalidateQueries({ queryKey: ['products', id] })
      navigate({ to: '/products/$id', params: { id } })
    },
    onError: (e: Error) => setError(e.message),
  })

  if (isLoading) return <p className="text-gray-500">Loading...</p>

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault(); setError(null)
    mutation.mutate({ name: form.name, description: form.description || null, price: Number(form.price), stock: Number(form.stock) })
  }

  return (
    <div className="max-w-lg">
      <h1 className="text-2xl font-bold text-slate-900 mb-6">Edit Product</h1>
      {error && <p className="bg-red-50 text-red-700 p-3 rounded mb-4 text-sm">{error}</p>}
      <form onSubmit={handleSubmit} className="bg-white rounded-lg shadow-sm p-6 space-y-4">
        <div><label className={labelCls}>Name *</label><input required className={inputCls} value={form.name} onChange={set('name')} /></div>
        <div><label className={labelCls}>Description</label><textarea className={inputCls} rows={3} value={form.description} onChange={set('description')} /></div>
        <div><label className={labelCls}>Price *</label><input required type="number" min="0" step="0.01" className={inputCls} value={form.price} onChange={set('price')} /></div>
        <div><label className={labelCls}>Stock</label><input type="number" min="0" className={inputCls} value={form.stock} onChange={set('stock')} /></div>
        <div className="flex gap-3">
          <button type="submit" disabled={mutation.isPending}
                  className="flex-1 bg-slate-900 text-white py-2 rounded hover:bg-slate-700 disabled:opacity-50">
            {mutation.isPending ? 'Saving...' : 'Save Changes'}
          </button>
          <button type="button" onClick={() => navigate({ to: '/products/$id', params: { id } })}
                  className="flex-1 border border-gray-300 py-2 rounded hover:bg-gray-50">
            Cancel
          </button>
        </div>
      </form>
    </div>
  )
}
