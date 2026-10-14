# Decision: how the Admin creates and deactivates user accounts (Sprint 4, issue 40)

- **Status:** accepted (Option A)
- **Requirements:** REQ-ADM-01 (create, update, deactivate accounts), REQ-ADM-02 (RBAC),
  SEC-02 (RLS on every table), SEC-06 (secret handling)
- **Code:** `lib/data/admin-users-actions.ts`, `lib/supabase/admin.ts`, `lib/mail.ts`
- **Database:** `docs/database/admin_users.sql`

## Problem

Some account work cannot be done with a signed-in user's session: creating a Supabase Auth user,
blocking one from signing in, and generating a set-password link all need the Supabase **admin
key**. That key bypasses Row Level Security, so where it lives decides how safe the whole database
is. SEC-06 says it must never be used in frontend code or exposed to the browser.

## Options

| Option | What it means | Verdict |
| --- | --- | --- |
| **A. Server-only environment variable** | The key is set only as a server environment variable on Vercel and is read by one server-only module. Server Actions use it after proving the caller is an active Admin. | **Chosen** |
| B. Supabase Edge Function / database function | The privileged step moves into Supabase; the app calls it with the user's session. | Rejected for now: a second runtime to build, deploy and secure in a 12-day schedule, and the Auth admin API is still needed inside it. |
| C. No admin API; use the Supabase dashboard / SQL editor | The Backend team creates accounts by hand. | Rejected: does not satisfy REQ-ADM-01 (an Admin interface). Remains the break-glass path. |

## Decision (Option A)

1. **Where the key lives.** Only in the server environment variable `SUPABASE_ADMIN_KEY` (Vercel:
   Project Settings, Environment Variables, not exposed to the browser; locally in `.env.local`,
   which git ignores). It is the Supabase `service_role` key under the name this repo already uses;
   the name is project-specific on purpose, so the repo's SQL scrub (which forbids the literal role
   name) and a search for the usual name both stay clean.
2. **Never public.** It never has a `NEXT_PUBLIC_` name (those are bundled into the browser), is never
   in a repo file (code, SQL, docs, `.env.example`), and is never in client code.
3. **One reader.** Only `lib/supabase/admin.ts` reads it. That file starts with `import 'server-only'`,
   so the build fails if a Client Component ever imports it.
4. **Proof before use.** `getAdminClientFor('Admin')` first checks the caller's own session: signed in,
   profile active, role `Admin`. Only then does it build the client. Every action in
   `admin-users-actions.ts` calls it first; a signed-out, deactivated or non-Admin caller gets
   "session ended" or "not allowed" and the key is never touched.
5. **Smallest use.** The admin client is used only for: Auth `createUser`, `updateUserById` (ban or
   unban), `generateLink`, `deleteUser` (undo of a half-created account), reading `roles` and the
   email-in-use check, and `profiles` INSERT / DELETE (the server role's grants from
   `applications_server_grants.sql`).
6. **Session first for data.** Editing a profile (`first_name`, `last_name`, `role_id`, `is_active`)
   and the department assignment (`department_staff`) use the Admin's **own session**, so RLS
   (`profiles_admin_write`, `dept_staff_admin_write`), the column grants and the last-admin trigger
   are the final gate, not application code.
7. **No secrets out.** Nothing returns, logs or emails a key or a password. A new account gets a long
   random password nobody sees; the person sets their own through a one-time link.

## Deactivation

"Deactivate" means `profiles.is_active = false`, never a delete.

- The database effect is immediate: `private.active_uid()` and `private.current_role_name()` ignore
  inactive profiles, so every RLS policy stops matching, even for a session token that has not expired.
- The server action then bans the Auth user (about 100 years) so the person cannot sign in or refresh a
  session. Reactivation reverses both. If the ban step fails, the action says so and the Admin retries;
  the database cut-off already applies.
- `private.trg_prevent_last_admin_deactivation()` refuses any change that would leave no active Admin
  (also for role changes), for every caller. An Admin also cannot deactivate or demote their own
  account in the app.

## Consequences and residual risks

- **The key is powerful.** Anyone who can read the Vercel environment, or a server log that prints it,
  has full database access. Mitigation: team access to Vercel limited to who needs it; rotate the key
  in Supabase (Project Settings, API) if it is ever shown or leaked, then update the Vercel variable
  and redeploy.
- **The Admin is trusted.** A compromised Admin account can create accounts. Mitigations already in
  place: every change is in the audit log with the Admin as actor, new accounts get no password, and
  the first Admin sign-ins are protected by the login lockout (SEC-03).
- **Two writers for one account.** Auth and `profiles` are separate systems with no shared
  transaction. Creation is ordered (Auth user, profile, department) and undoes what it created if a
  later step fails; if the undo itself fails the Admin sees a message naming the email to check.
- **No UI wiring yet.** `components/admin/UsersTable.tsx` is still the sample-data table; the
  Frontend team calls the four actions from it (`createStaffAccount`, `updateUserAccount`,
  `setUserActive`, `resendStaffInvite`), which all have the `(prevState, formData)` shape used with
  `useActionState`.

## Differences from the issue text

- The issue says `SUPABASE_SERVICE_ROLE_KEY`. The repo already uses `SUPABASE_ADMIN_KEY` (see
  `lib/supabase/admin.ts`, the Registrar's account provisioning, and the SQL scrub); the same key
  under the existing name was kept so there is one variable to guard, not two.
- The issue lists `profiles.department_id`. `profiles` has no such column; the department is the row
  in `department_staff`, which is what the grants and the action write.
