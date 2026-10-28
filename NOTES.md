# Notes

Context for reviewers: decisions, trade-offs and what I'd do next. Setup, the permission matrix and an overview of the approach are in the [README](./README.md#role-based-access-control).

## Decisions

- **Permissions, not role checks.** Endpoints ask "does this user have `users:read`?", never "is this user a manager?". All role knowledge lives in `ROLE_PERMISSIONS`, so changing what a role can do is a one-line change.
- **A role column instead of a roles table.** Three fixed roles don't justify a join table and an admin UI for editing roles. A `VARCHAR` column keeps queries trivial and lets a new role ship without a migration. If roles ever need to be editable at runtime, `ROLE_PERMISSIONS` would move to the database behind the same `permissions_for()` function.
- **FastAPI dependencies instead of middleware.** Middleware runs before routing and can't see which permission a route needs. Dependencies are declared per route, show up in code review, and reuse `get_current_user`.
- **`is_superuser` is removed, not kept next to `role`.** Two sources of truth would invite a missed check somewhere.
- **The 401/403 split was a prerequisite.** The template returned 403 for invalid tokens, and the frontend logged out on any 403. With RBAC, that would have logged a manager out the first time they hit a forbidden endpoint. Invalid tokens now return 401, and only 401 logs the user out.
- **Admins can't lock themselves out.** They can't delete, demote or deactivate their own account (`PATCH`/`DELETE /users/{id}` on yourself returns 403). The UI already hid row actions on your own row; the API now enforces it.

## Security fixes found along the way

- `POST /password-recovery-html-content/{email}` returns a working password-reset token for any user. It stays admin-only through `users:update`, because it amounts to "change anyone's password".
- `GET /users/{id}` checks the permission before the 404, so a member can't use it to find out which user ids exist.
- Signup and `PATCH /users/me` have no `role` field, so a submitted `role` is ignored. Tests cover both.

## Trade-offs and scope cuts

- **The Users page is still served at `/admin`.** It's labelled "Users" in the UI, but I didn't rename the route, because several existing Playwright specs navigate to `/admin`.
- **The frontend has one role check.** The settings page hides the "Danger zone" tab for admins by checking `role === "admin"` directly. It mirrors a self-protection rule rather than a permission. It's the only role check in the frontend.
- **The metrics are intentionally simple:** a few `count()` queries.
- **No audit log table.** Denied attempts are logged as warnings, which is enough for local debugging but not for compliance.

## With more time

- Add an `audit_log` table for role changes and denied attempts.
- Move route guards into TanStack Router `beforeLoad` with a router context, so a page's permission sits next to its route definition.
- Add a "last admin" check in the database, for example a deferred constraint or a check in `crud.update_user`, so a future endpoint can't bypass the self-protection rule.
- Write an architecture decision record (ADR) for the decisions above.
