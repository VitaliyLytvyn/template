import { useState, useEffect } from 'react'
import { Link, useNavigate } from 'react-router-dom'

function DataList() {
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  useEffect(() => {
    fetchItems()
  }, [])

  const fetchItems = () => {
    fetch('/api/items')
      .then(res => {
        if (!res.ok) throw new Error('Failed to fetch items')
        return res.json()
      })
      .then(data => {
        setItems(data)
        setLoading(false)
      })
      .catch(err => {
        setError(err.message)
        setLoading(false)
      })
  }

  const handleItemAdded = () => {
    fetchItems()
  }

  const handleDelete = (id) => {
    if (!confirm('Are you sure you want to delete this item?')) return
    fetch(`/api/items/${id}`, { method: 'DELETE' })
      .then(res => {
        if (!res.ok) throw new Error('Failed to delete item')
        return res.json()
      })
      .then(() => {
        setItems(prev => prev.filter(item => item.id !== id))
      })
      .catch(err => {
        alert(err.message)
      })
  }

  if (loading) return <div className="loading">Loading...</div>
  if (error) return <div className="error">Error: {error}</div>

  return (
    <div>
      <div className="page-header">
        <h1>Data List</h1>
        <Link to="/data/create" className="btn">Add New Item</Link>
      </div>
      {items.length === 0 ? (
        <p className="empty-state">No items found</p>
      ) : (
        <ul className="item-list">
          {items.map(item => (
            <li key={item.id} className="item-card">
              <div className="item-content">
                <Link to={`/data/${item.id}`} className="item-link">
                  <h3>{item.name}</h3>
                  <p>{item.description || 'No description'}</p>
                  <small className="item-date">Created: {new Date(item.created_at).toLocaleString()}</small>
                </Link>
              </div>
              <div className="item-actions">
                <Link to={`/data/${item.id}/edit`} className="btn btn-edit">Edit</Link>
                <button onClick={() => handleDelete(item.id)} className="btn btn-delete">Delete</button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

export default DataList