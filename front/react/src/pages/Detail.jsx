import { useState, useEffect } from 'react'
import { useParams, Link, useNavigate } from 'react-router-dom'

function Detail() {
  const { id } = useParams()
  const navigate = useNavigate()
  const [item, setItem] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  useEffect(() => {
    fetch(`/api/items/${id}`)
      .then(res => {
        if (!res.ok) throw new Error('Failed to fetch item')
        return res.json()
      })
      .then(data => {
        setItem(data)
        setLoading(false)
      })
      .catch(err => {
        setError(err.message)
        setLoading(false)
      })
  }, [id])

  const handleDelete = () => {
    if (!confirm('Are you sure you want to delete this item?')) return
    fetch(`/api/items/${id}`, { method: 'DELETE' })
      .then(res => {
        if (!res.ok) throw new Error('Failed to delete item')
        navigate('/data')
      })
      .catch(err => {
        alert(err.message)
      })
  }

  if (loading) return <div className="loading">Loading...</div>
  if (error) return <div className="error">Error: {error}</div>
  if (!item) return <div className="error">Item not found</div>

  return (
    <div>
      <div className="detail-header">
        <Link to="/data" className="back-link">&larr; Back to list</Link>
        <div className="detail-title-row">
          <h1>{item.name}</h1>
          <div className="detail-actions">
            <Link to={`/data/${item.id}/edit`} className="btn btn-edit">Edit</Link>
            <button onClick={handleDelete} className="btn btn-delete">Delete</button>
          </div>
        </div>
      </div>
      <div className="card">
        <p><strong>Description:</strong> {item.description || 'No description'}</p>
        <p><strong>Created:</strong> {new Date(item.created_at).toLocaleString()}</p>
        <p><strong>Updated:</strong> {new Date(item.updated_at).toLocaleString()}</p>
      </div>
    </div>
  )
}

export default Detail
