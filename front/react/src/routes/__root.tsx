import { createRootRoute, Outlet, Link } from '@tanstack/react-router'

export const Route = createRootRoute({
  component: () => (
    <div className="min-h-screen bg-gray-50">
      <nav className="bg-slate-900 text-white px-6 py-4 flex justify-between items-center">
        <Link to="/" className="text-xl font-bold">Full Stack App</Link>
        <div className="flex gap-6">
          <Link to="/" className="hover:text-gray-300 [&.active]:text-white">Home</Link>
          <Link to="/products" className="hover:text-gray-300 [&.active]:text-white">Products</Link>
        </div>
      </nav>
      <main className="max-w-5xl mx-auto px-6 py-8"><Outlet /></main>
    </div>
  ),
})
