# Full Stack FastAPI Template

[![Test Docker Compose](../../actions/workflows/test-docker-compose.yml/badge.svg)](../../actions/workflows/test-docker-compose.yml)
[![Test Backend](../../actions/workflows/test-backend.yml/badge.svg)](../../actions/workflows/test-backend.yml)

## Role-Based Access Control

This project adds three roles, **admin**, **manager** and **member**, enforced in both the API and the UI.

### Quick start

Requirements: [Docker](https://www.docker.com/), [uv](https://docs.astral.sh/uv/), [Bun](https://bun.sh/), and Node.js 22 or newer (Bun runs Vite and Playwright through Node when Node is installed).

```bash
# 1. Start Postgres and Mailpit
docker compose up -d db mailpit

# 2. Backend: install dependencies, run migrations, create the first admin, seed demo users
cd backend
uv sync
uv run bash scripts/prestart.sh
uv run python app/seed_demo_users.py
uv run fastapi dev            # API on http://localhost:8000, docs on http://localhost:8000/docs

# 3. Frontend, in a second terminal from the repository root
bun install
bun run dev                   # UI on http://localhost:5173
```

### Demo accounts

`prestart.sh` creates the admin from `FIRST_SUPERUSER` in `.env`. `seed_demo_users.py` adds one user for each of the other roles. It is idempotent and only runs when `FASTAPI_ENV=development` (the default in `.env`).

| Role | Email | Password |
|---|---|---|
| admin | `admin@example.com` | `changethis` |
| manager | `manager@example.com` | `changethis` |
| member | `member@example.com` | `changethis` |

> The backend test suite deletes **all** users when it finishes (existing template behavior). Afterwards, run `uv run bash scripts/prestart.sh && uv run python app/seed_demo_users.py` again.

### Permission matrix

| Action | Endpoint | Rule | admin | manager | member |
|---|---|---|:-:|:-:|:-:|
| View and update own profile and password | `GET`/`PATCH /users/me`, `PATCH /users/me/password` | signed in; `role` can't be changed here | ✓ | ✓ | ✓ |
| Delete own account | `DELETE /users/me` | signed in, except admins | ✗ | ✓ | ✓ |
| List users | `GET /users/` | `users:read` | ✓ | ✓ | ✗ |
| View any user | `GET /users/{id}` | self, or `users:read` | ✓ | ✓ | self only |
| Create user | `POST /users/` | `users:create` | ✓ | ✗ | ✗ |
| Update any user, including role | `PATCH /users/{id}` | `users:update`, not on self | ✓ | ✗ | ✗ |
| Delete any user | `DELETE /users/{id}` | `users:delete`, not on self | ✓ | ✗ | ✗ |
| Get the password-reset email for any user | `POST /password-recovery-html-content/{email}` | `users:update` | ✓ | ✗ | ✗ |
| View metrics | `GET /metrics/` | `metrics:read` | ✓ | ✓ | ✗ |
| Global settings (send a test email) | `POST /utils/test-email/` | `settings:manage` | ✓ | ✗ | ✗ |
| Create, read, update, delete own items | `/items/*` | owner | ✓ | ✓ | ✓ |
| Read and change other users' items | `/items/*` | `items:manage_all` | ✓ | ✗ | ✗ |
| Sign up | `POST /users/signup` | public, always creates a `member` | – | – | – |

In the UI, managers see the **Users** page read-only and the **Metrics** page. Members see neither, and opening those URLs directly shows an "Access denied" page.

### How it works

**Roles are stored on the user.** `user.role` is a `VARCHAR` column validated by the `UserRole` enum. It replaces `is_superuser`, and the migration turns existing superusers into admins. Using a `VARCHAR` instead of a native Postgres enum means a new role needs no database migration. The role is read from the database on every request rather than stored in the JWT, so a role change applies immediately, even to tokens that were already issued.

**One policy file, permission checks on the routes.** [`backend/app/core/permissions.py`](./backend/app/core/permissions.py) maps each role to a set of permissions, and it is the only place that knows which role can do what. Endpoints check permissions, never roles. They declare what they need with a FastAPI dependency, for example `dependencies=[Depends(require_permission(Permission.USERS_READ))]`. Checks that depend on ownership, such as your own profile or your own items, call `has_permission()` inside the handler. A denied request returns `403` and logs the user, role, permission and path. A missing or invalid token returns `401`. Self-protection rules guarantee at least one admin: admins can't delete, demote or deactivate themselves.

**The frontend asks, it doesn't decide.** `GET /users/me` returns the user's `permissions`, and the UI only ever calls `can("users:read")` from [`usePermissions`](./frontend/src/hooks/usePermissions.ts). Navigation links and buttons are hidden based on it. Protected pages are wrapped in [`<RequirePermission>`](./frontend/src/components/Common/RequirePermission.tsx), which shows a friendly 403 page (with the sidebar still visible) instead of redirecting. Only a `401` logs the user out. The frontend checks are only for UX: the API enforces every rule on its own.

### Adding a role

1. Add the role to `UserRole` and give it a permission set in `ROLE_PERMISSIONS` ([`permissions.py`](./backend/app/core/permissions.py)). A test fails if you forget the permission set.
2. Regenerate the frontend client: `bash scripts/generate-client.sh`.
3. Add a label in [`frontend/src/lib/roles.ts`](./frontend/src/lib/roles.ts). TypeScript reports it as missing until you do.

Removing a role is different: first add a migration that moves its users to another role. A user whose stored role no longer exists gets no permissions, but endpoints that list users then fail with a 500 error.

### Running tests

Backend (needs the `db` service running):

```bash
cd backend
uv run bash scripts/test.sh   # pytest with coverage; RBAC cases are in tests/api/routes/test_rbac.py
uv run bash scripts/lint.sh   # mypy, ty and ruff
```

UI end-to-end tests (need the backend running on port 8000 with `FASTAPI_ENV=development`, which enables the test-only `/private/users/` endpoint):

```bash
cd frontend
bunx playwright install chromium   # first time only
bun run test                       # all specs; RBAC cases are in tests/rbac.spec.ts
```

### Database migrations

```bash
cd backend
uv run alembic upgrade head                                       # apply migrations (prestart.sh runs this)
uv run alembic revision --autogenerate -m "Describe the change"   # create one after changing models
```

## Technology Stack and Features

- ⚡ [**FastAPI**](https://fastapi.tiangolo.com) for the Python backend API.
  - 🧰 [SQLModel](https://sqlmodel.tiangolo.com) for the Python SQL database interactions (ORM).
  - 🔍 [Pydantic](https://docs.pydantic.dev), used by FastAPI, for the data validation and settings management.
  - 💾 [PostgreSQL](https://www.postgresql.org) as the SQL database.
- 🚀 [React](https://react.dev) for the frontend.
  - 🧩 Built into the backend application and served by FastAPI on the same domain as the API.
  - 💃 Using TypeScript, hooks, [Vite](https://vitejs.dev), and other parts of a modern frontend stack.
  - 🎨 [Tailwind CSS](https://tailwindcss.com) and [shadcn/ui](https://ui.shadcn.com) for the frontend components.
  - 🤖 An automatically generated frontend client.
  - 🧪 [Playwright](https://playwright.dev) for end-to-end testing.
  - 🦇 Dark mode support.
- ☁️ [FastAPI Cloud](https://fastapicloud.com) for deployment.
- 🐋 [Docker Compose](https://www.docker.com) for local services and self-hosted deployment.
  - 📞 [Traefik](https://traefik.io) as a reverse proxy with automatic HTTPS.
- 🔒 Secure password hashing by default.
- 🔑 JWT (JSON Web Token) authentication.
- 📫 Email-based password recovery.
- ✉️ [React Email](https://react.email) for email templates.
- 📬 [Mailpit](https://mailpit.axllent.org) for local email testing during development.
- ✅ Tests with [Pytest](https://pytest.org).
- 🏭 CI (continuous integration) and CD (continuous deployment) based on GitHub Actions.

### Dashboard Login

![Dashboard login screenshot](img/login.png)

### Dashboard - Admin

![Admin dashboard screenshot](img/dashboard.png)

### Dashboard - Items

![Items dashboard screenshot](img/dashboard-items.png)

### Dashboard - Dark Mode

![Dark mode dashboard screenshot](img/dashboard-dark.png)

### React Email Templates

![Email templates screenshot](img/react-email.png)

### Mailpit - Local Email Testing

![Mailpit screenshot](img/mailpit.png)

### Interactive API Documentation

![API docs](img/docs.png)

## How to Use It

Click the **Use this template** button at the top of this page to create a new repository.

## Backend Development

Backend docs: [backend/README.md](./backend/README.md).

## Frontend Development

Frontend docs: [frontend/README.md](./frontend/README.md).

## Deployment

FastAPI Cloud deployment: [deployment.md](./deployment.md).

Self-hosted deployment with Docker Compose: [deployment-docker-compose.md](./deployment-docker-compose.md).

## Development

General development docs: [development.md](./development.md).

This includes the local FastAPI and Vite workflow, Docker Compose services, `.env` configuration, and more.

## Release Notes

Check the file [release-notes.md](./release-notes.md).

## License

The Full Stack FastAPI Template is licensed under the terms of the MIT license.
