import { useState, useEffect } from 'react'
import { useParams, useNavigate } from 'react-router-dom'

function EditItemForm() {
  const { id } = useParams()
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [success, setSuccess] = useState(null)

  useEffect(() => {
    fetch(`/api/items/${id}`)
      .then(res => {
        if (!res.ok) throw new Error('Failed to fetch item')
        return res.json()
      })
      .then(data => {
        setName(data.name || '')
        setDescription(data.description || '')
        setLoading(false)
      })
      .catch(err => {
        setError(err.message)
        setLoading(false)
      })
  }, [id])

  const handleSubmit = async (e) => {
    e.preventDefault()
    setLoading(true)
    setError(null)
    setSuccess(null)

    try {
      const response = await fetch(`/api/items/${id}`, {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ name, description }),
      })

      if (!response.ok) {
        const errorData = await response.json()
        throw new Error(errorData.error || 'Failed to update item')
      }

      setSuccess('Item updated successfully!')
      setTimeout(() => navigate(`/data/${id}`), 800)
    } catch (err) {
      setError(err.message)
      setLoading(false)
    }
  }

  if (loading) return <div className="loading">Loading...</div>
  if (error) return <div className="error">Error: {error}</div>

  return (
    <div className="edit-item-form">
      <h2>Edit Item</h2>
      {error && <div className="error">{error}</div>}
      {success && <div className="success">{success}</div>}
      <form onSubmit={handleSubmit}>
        <div className="form-group">
          <label htmlFor="name">Name:</label>
          <input
            type="text"
            id="name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            required
          />
        </div>
        <div className="form-group">
          <label htmlFor="description">Description:</label>
          <textarea
            id="description"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </div>
        <div className="form-actions">
          <button type="submit">Update Item</button>
          <button type="button" onClick={() => navigate(`/data/${id}`)}>Cancel</button>
        </div>
      </form>
    </div>
  )
}

export default EditItemForm