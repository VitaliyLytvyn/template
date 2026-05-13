import { createFileRoute, Link, useNavigate } from '@tanstack/react-router'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { fetchProducts, deleteProduct } from '../../api/products'

export const Route = createFileRoute('/products/')({ component: ProductList })

function ProductList() {
  const qc = useQueryClient()
  const navigate = useNavigate()
  const { data, isLoading, error } = useQuery({
    queryKey: ['products'],
    queryFn: () => fetchProducts(),
  })
  const deleteMutation = useMutation({
    mutationFn: deleteProduct,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['products'] }),
  })

  if (isLoading) return <p className="text-gray-500">Loading...</p>
  if (error)     return <p className="text-red-600">Error: {(error as Error).message}</p>

  return (
    <div>
      <div className="flex justify-between items-center mb-6">
        <h1 className="text-2xl font-bold text-slate-900">Products</h1>
        <Link to="/products/create" className="bg-slate-900 text-white px-4 py-2 rounded text-sm hover:bg-slate-700">
          Add Product
        </Link>
      </div>
      {!data?.data.length ? (
        <p className="text-gray-400 text-center py-12">No products yet.</p>
      ) : (
        <div className="bg-white rounded-lg shadow-sm overflow-hidden">
          <table className="w-full text-sm">
            <thead className="bg-gray-50 text-gray-700">
              <tr>{['Name','Price','Stock','Actions'].map(h => <th key={h} className="px-4 py-3 text-left font-medium">{h}</th>)}</tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {data.data.map(p => (
                <tr key={p.id} className="hover:bg-gray-50 cursor-pointer"
                    onClick={() => navigate({ to: '/products/$id', params: { id: String(p.id) } })}>
                  <td className="px-4 py-3 font-medium">{p.name}</td>
                  <td className="px-4 py-3 text-gray-600">${p.price}</td>
                  <td className="px-4 py-3 text-gray-600">{p.stock}</td>
                  <td className="px-4 py-3" onClick={e => e.stopPropagation()}>
                    <Link to="/products/$id/edit" params={{ id: String(p.id) }}
                          className="text-blue-600 hover:underline mr-4 text-xs">Edit</Link>
                    <button onClick={() => confirm('Delete?') && deleteMutation.mutate(p.id)}
                            className="text-red-600 hover:underline text-xs">Delete</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {data?.meta && (
        <p className="text-xs text-gray-400 mt-4">
          {data.meta.total} total · page {data.meta.page} of {Math.ceil(data.meta.total / data.meta.limit)}
        </p>
      )}
    </div>
  )
}
