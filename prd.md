I need a full stack infrastructure for TESTING purposes.

Overview:
- Simple as possible, open to extension
- Full stack app: Frontend + Backend + DB
- Framework/dependency versions: production ready versions as of the beggining of 2026, stable/LTS, not bleeding edge
- BE and FE: deployable both natively ("as is") or via Docker
- DB: Docker container only
- Bash script with two deployment modes:
  1. Native: starts BE and FE with their regular tooling, DB in Docker
  2. Docker: all 3 via docker-compose
- Bash script operations: start, stop, status, logs, rebuild/clean, reset DB

Structure:
- 3 distinct directories: `backend/`, `front/`, `db/`
- Each dir may contain multiple implementations: `backend/nodejs/`, `backend/java/`, etc.

Backend:
- Node.js + Express in `backend/nodejs/`
- CRUD endpoints for a sample resource
- File upload endpoint
- Simple, well-documented API

Frontend:
- React app in `front/react/`
- 3 pages:
  - Home: landing/overview
  - Data List: displays items from backend API
  - Detail: shows individual item details
- No authentication/authorization
- Standard, clean design

DB:
- MySQL in `db/mysql/`
- Docker container only
- Initialized schema with sample seed data on first run
- Versioned SQL migration files in `db/mysql/migrations/`

Bash Script:
- Two deployment modes:
  - Native: BE + FE run locally, DB in Docker
  - Docker Compose: all 3 orchestrated
- Commands: `start`, `stop`, `status`, `logs`, `rebuild`, `reset-db`
