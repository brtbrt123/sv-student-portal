# Centralized Student Portal and Automated Clearance System

Pamantasan ng Cabuyao (PnC), BS Computer Science project. A role-based portal where students, the Registrar, the Cashier, department staff and the Admin handle enrollment, grades, charges, document requests and the term clearance in one place.

**Stack:** Next.js 16 (App Router, TypeScript), React 19, Tailwind CSS 4, Supabase (PostgreSQL, Auth, Row Level Security) with `@supabase/ssr`, deployed on Vercel.

> This Next.js version has breaking changes (for example `proxy.ts` replaces `middleware.ts`, and `cookies()` is async). Read `AGENTS.md` and `node_modules/next/dist/docs/` before writing code.

## Getting started

```bash
git clone https://github.com/brtbrt123/sv-student-portal.git
cd sv-student-portal
npm install
```

Create `.env.local` in the project root (it is git-ignored; never commit it):

```
NEXT_PUBLIC_SUPABASE_URL=<your Supabase project URL>
NEXT_PUBLIC_SUPABASE_ANON_KEY=<your Supabase anon key>
```

Backend work also needs these server-only variables (no `NEXT_PUBLIC_` prefix): `SUPABASE_ADMIN_KEY`, `QUEUE_QR_SECRET` (at least 32 characters), `SITE_URL`, `RESEND_API_KEY` and `MAIL_FROM`.

Ask the Project Manager for the values. The server-side key must never be in the browser code or the repository.

```bash
npm run dev     # http://localhost:3000
```

| Command | Purpose |
| --- | --- |
| `npm run dev` | Start the dev server |
| `npm run build` | Production build (run before opening a pull request) |
| `npm run lint` | ESLint |
| `npx tsc --noEmit` | Type check |

## Project structure

| Path | Contents |
| --- | --- |
| `app/(auth)/login` | Login page and sign-in action |
| `app/(modules)/<role>` | Screens for Student, Registrar, Cashier, Department, Admin |
| `components/ui` | Shared components: Button, Input, Card, Table, Badge |
| `components/layout` | Dashboard shell with the role-based sidebar |
| `lib/nav.ts` | Sidebar links per role |
| `lib/auth`, `lib/supabase` | Roles, session helpers, password rules, Supabase clients |
| `lib/data`, `lib/queue`, `lib/notifications` | Database reads and writes per module, the queue and notification helpers |
| `app/apply` | Public application site (no login) |
| `proxy.ts` | Session refresh and role-based route protection |
| `docs/database` | `schema.sql`, the rule files, `seed.sql`, `rls.sql` and the order to run them (29 tables) |
| `docs/diagrams` | ERD (overview and detailed), UML Class, DFD, Use Case and Activity diagrams (SVG). `scripts/diagrams` regenerates them; editable copies are in Figma (https://www.figma.com/design/caIH5zcYI3ursQ9c2iYFJg) |
| `docs/documentation.md` | Project Charter, SRS, architecture, onboarding guide |

Colors come from the design tokens in `app/globals.css` (Figma file `Cabuyao_Uni`); use classes such as `bg-card`, `text-muted` and `bg-success-soft` instead of hard-coded colors.

## Git workflow

1. Never code on `main` or `dev`.
2. Branch from `dev` as `feature/<task>` (or `chore/<task>`, `docs/<task>`), commit, push.
3. Open a pull request with base **`dev`** and ask a teammate to review it. Check the base branch before you merge.
4. Only the Project Manager merges `dev` into `main` at the end of a sprint. Vercel deploys every change to `main`.

## Test accounts

The seeded accounts are `student1@pnc.test`, `student2@pnc.test`, `student3@pnc.test`, `registrar@pnc.test`, `cashier@pnc.test`, `dept@pnc.test` and `admin@pnc.test`. Passwords are held by the Project Manager. All data is fictional.
