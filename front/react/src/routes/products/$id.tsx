import { createFileRoute, Link, useNavigate } from '@tanstack/react-router'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { fetchProduct, deleteProduct } from '../../api/products'

export const Route = createFileRoute('/products/$id')({ component: ProductDetail })

function ProductDetail() {
  const { id } = Route.useParams()
  const navigate = useNavigate()
  const qc = useQueryClient()
  const { data, isLoading, error } = useQuery({
    queryKey: ['products', id],
    queryFn: () => fetchProduct(Number(id)),
  })
  const deleteMutation = useMutation({
    mutationFn: () => deleteProduct(Number(id)),
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['products'] }); navigate({ to: '/products' }) },
  })

  if (isLoading) return <p className="text-gray-500">Loading...</p>
  if (error)     return <p className="text-red-600">Error: {(error as Error).message}</p>
  if (!data)     return <p className="text-red-600">Not found</p>

  const p = data.data
  return (
    <div>
      <Link to="/products" className="text-slate-600 hover:underline text-sm">← Back</Link>
      <div className="mt-4 bg-white rounded-lg shadow-sm p-6">
        <div className="flex justify-between items-start mb-4">
          <h1 className="text-2xl font-bold text-slate-900">{p.name}</h1>
          <div className="flex gap-2">
            <button onClick={() => navigate({ to: '/products/$id/edit', params: { id: String(p.id) } })}
                    className="bg-amber-400 text-slate-900 px-3 py-1 rounded text-sm">Edit</button>
            <button onClick={() => confirm('Delete?') && deleteMutation.mutate()}
                    className="bg-red-500 text-white px-3 py-1 rounded text-sm">Delete</button>
          </div>
        </div>
        {p.image_path && <img src={p.image_path} alt={p.name} className="w-48 h-48 object-cover rounded mb-4" />}
        <p className="text-gray-600 mb-4">{p.description ?? 'No description'}</p>
        <dl className="grid grid-cols-2 gap-2 text-sm">
          <dt className="text-gray-500">Price</dt><dd className="font-medium">${p.price}</dd>
          <dt className="text-gray-500">Stock</dt><dd className="font-medium">{p.stock}</dd>
          <dt className="text-gray-500">Created</dt><dd>{new Date(p.created_at).toLocaleString()}</dd>
          <dt className="text-gray-500">Updated</dt><dd>{new Date(p.updated_at).toLocaleString()}</dd>
        </dl>
      </div>
    </div>
  )
}
