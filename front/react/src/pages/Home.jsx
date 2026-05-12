import { Link } from 'react-router-dom'

function Home() {
  return (
    <div className="hero">
      <h1>Welcome to Full Stack App</h1>
      <p>A simple full stack application for testing purposes.</p>
      <div>
        <Link to="/data" className="btn">View Data List</Link>
      </div>
      <div className="grid" style={{ marginTop: '3rem', textAlign: 'left' }}>
        <div className="card">
          <h2>Backend</h2>
          <p>Node.js + Express API with CRUD endpoints and file upload support.</p>
        </div>
        <div className="card">
          <h2>Frontend</h2>
          <p>React application with routing and clean design.</p>
        </div>
        <div className="card">
          <h2>Database</h2>
          <p>MySQL container with migrations and seed data.</p>
        </div>
      </div>
    </div>
  )
}

export default Home
