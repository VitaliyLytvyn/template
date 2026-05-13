import { createFileRoute, Link } from '@tanstack/react-router'

export const Route = createFileRoute('/')({
  component: () => (
    <div className="text-center py-16">
      <h1 className="text-4xl font-bold text-slate-900 mb-4">Full Stack Template</h1>
      <p className="text-lg text-gray-600 mb-8">Production-grade Node.js + React app.</p>
      <Link to="/products" className="bg-slate-900 text-white px-6 py-3 rounded hover:bg-slate-700">
        View Products
      </Link>
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mt-16 text-left">
        {[
          ['Backend', 'Express 5 · TypeScript · Drizzle ORM · Pino'],
          ['Frontend', 'React 19 · TanStack Router · TanStack Query · Tailwind v4'],
          ['Database', 'MySQL 8.4 · Drizzle Kit migrations · Docker'],
        ].map(([title, desc]) => (
          <div key={title} className="bg-white rounded-lg p-6 shadow-sm">
            <h2 className="font-semibold text-slate-900 mb-2">{title}</h2>
            <p className="text-gray-600 text-sm">{desc}</p>
          </div>
        ))}
      </div>
    </div>
  ),
})
