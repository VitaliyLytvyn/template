import { Routes, Route, Link } from 'react-router-dom'
import Home from './pages/Home'
import DataList from './pages/DataList'
import Detail from './pages/Detail'
import AddItemForm from './components/AddItemForm'
import EditItemForm from './components/EditItemForm'

function App() {
  return (
    <div className="app">
      <nav className="navbar">
        <div className="nav-brand">
          <Link to="/">Full Stack App</Link>
        </div>
        <ul className="nav-links">
          <li><Link to="/">Home</Link></li>
          <li><Link to="/data">Data List</Link></li>
        </ul>
      </nav>
      <main className="main-content">
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/data" element={<DataList />} />
          <Route path="/data/create" element={<AddItemForm />} />
          <Route path="/data/:id" element={<Detail />} />
          <Route path="/data/:id/edit" element={<EditItemForm />} />
        </Routes>
      </main>
    </div>
  )
}

export default App