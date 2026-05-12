# AGENTS.md - Repository Guidelines

## Project Structure
- `backend/nodejs/` - Express API (CommonJS, Node 18)
- `front/react/` - React + Vite app (ESM, React 18)
- `db/mysql/` - MySQL Docker config + migrations
- `deploy.sh` - Deployment script (native/docker modes)
- `docker-compose.yml` - Full-stack Docker orchestration

## Commands

### Backend (backend/nodejs/)
```bash
npm install          # Install dependencies
npm start            # Run production server (port 3000)
npm run dev          # Run with nodemon (auto-reload)
```

### Frontend (front/react/)
```bash
npm install          # Install dependencies
npm run dev          # Start Vite dev server (port 5173)
npm run build        # Production build
npm run preview      # Preview production build
```

### Deployment
```bash
./deploy.sh start                    # Start all (docker mode default)
DEPLOY_MODE=native ./deploy.sh start # Native mode (BE/FE local, DB in Docker)
./deploy.sh stop                     # Stop all services
./deploy.sh status                   # Show service status
./deploy.sh logs [service]           # Follow logs
./deploy.sh rebuild                  # Rebuild and restart
./deploy.sh reset-db                 # Drop and recreate database
```

### Running a Single Test
No test framework configured. To add one:
- Backend: `npm install --save-dev jest` + add `"test": "jest"` to scripts
- Frontend: `npm install --save-dev vitest @testing-library/react` + add `"test": "vitest"` to scripts
Run single test: `npx jest path/to/test.test.js` or `npx vitest run path/to/test.test.jsx`

## Code Style

### Backend (CommonJS)
- **Imports**: `require()` for all imports. Third-party first, then local `./` prefix
- **Exports**: `module.exports = ...` for single export, `exports.foo = ...` for named
- **Formatting**: 2-space indent, semicolons required, single quotes for strings
- **Error handling**: Inline checks: `if (err) return res.status(500).json({ error: err.message })`
- **Response format**: `{ error: string }` for errors, direct JSON for success
- **SQL**: Parameterized queries only (`?` placeholders), never string interpolation
- **Validation**: Check required fields: `if (!name) return res.status(400).json({ error: '...' })`
- **Naming**: Files `snake_case`, variables `camelCase`, constants `UPPER_SNAKE_CASE`
- **Routing**: `express.Router()` per resource, mounted in `index.js`

### Frontend (ESM)
- **Imports**: ESM `import` syntax, no semicolons
  - Named: `import { useState } from 'react'`
  - Default: `import Home from './pages/Home'`
- **Components**: Functional only, no class components
- **Naming**: Files `PascalCase.jsx`, variables `camelCase`, CSS classes kebab-like (`.nav-brand`)
- **State**: `useState` + `useEffect` for data fetching, extract fetch logic to named functions
- **Fetch**: Raw `fetch()` with `.then()` chains, loading/error/success state pattern
- **Routing**: `react-router-dom` with `<Routes>` in `App.jsx`, use `useNavigate` for redirects
- **Props**: Components should manage their own data fetching rather than requiring callbacks
- **Conditional rendering**: Early returns for loading/error states

### CSS
- Single `index.css` file, no preprocessor or modules
- Reset: `* { margin: 0; padding: 0; box-sizing: border-box }`
- BEM-like class naming: `.card`, `.btn`, `.navbar`, `.item-card`, `.item-actions`
- Colors: `#1a1a2e` (primary dark), `#f5f5f5` (bg), `#333` (text), `#666` (secondary)

### Docker
- Backend: `node:18-alpine`, production-only install
- Frontend: `node:18-alpine`, full install (dev server in container)
- DB: `mysql:8.0`, migrations mounted to `/docker-entrypoint-initdb.d`

### Environment
- Backend reads from `.env` via `dotenv` (copy `.env.example` to `.env`)
- Frontend uses Vite proxy (`/api` -> `http://localhost:3000`) for dev
- Docker compose sets env vars directly in service config

### Git
- `.gitignore` excludes: `node_modules/`, `dist/`, `.env`, `*.pid`, `uploads/`
- Do not commit `.env` files (only `.env.example`)

### General
- No authentication/authorization in this codebase
- No TypeScript configured; plain JS/JSX throughout
- CRUD operations: GET all, GET by id, POST, PUT, DELETE
- File uploads supported via `/api/upload` (multer, disk storage)
- Database pool: `mysql2` with `waitForConnections: true`, limit 10
- If adding new patterns, match existing style in neighboring files
