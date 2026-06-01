---
name: uploads_dir
description: backend/nodejs/uploads/ is a runtime dir — never delete, preserve with .gitkeep
type: project
---

`backend/nodejs/uploads/` is the runtime upload directory used by `LocalDiskStorage` (`src/storage/local.storage.ts`).

- Already in `.gitignore` (root `.gitignore` has `uploads/`)
- `LocalDiskStorage.save()` calls `fs.mkdir(dir, { recursive: true })` — auto-creates at first upload
- Must be preserved in working tree via `.gitkeep` so a fresh clone has the dir ready
- `config.UPLOAD_DIR` defaults to `./uploads` (relative to backend process cwd)

**How to apply:** Never delete `backend/nodejs/uploads/`. If it disappears, restore with `mkdir -p backend/nodejs/uploads && touch backend/nodejs/uploads/.gitkeep`.
