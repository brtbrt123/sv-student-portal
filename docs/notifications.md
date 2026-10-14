# Notifications (in-app inbox for every role)

Built 2026-10-13. The Project Manager asked for one place where all notifications go, for all roles. Database:
`docs/database/notifications_rules.sql` (run live on 2026-10-13; its 32 tests pass; see `docs/testing-plan.md`). App: the
Notifications page of each role, the unread badge in the sidebar and the bell in the phone header.

## What the user sees

- **Notifications** is the last link of every sidebar (`/student/notifications`, `/registrar/notifications`, `/cashier/notifications`,
  `/department/notifications`, `/admin/notifications`). It shows the newest first, unread ones highlighted with a dot, "Mark all as
  read", and opens the related page when a notification is clicked (which also marks it read). The page refreshes every 20 seconds.
- The **unread count** shows as a gold badge on that link (desktop) and on a bell in the phone's top bar. It refreshes every 30 seconds.
- In-app only: no email, no push, no Realtime.

## Who gets what

| Recipient | Notification | When |
| --- | --- | --- |
| Student | You are in line / It is your turn / You were skipped | a queue ticket is issued / called / marked No-show |
| Student | Your enrollment was approved / rejected | the Registrar decides |
| Student | Document request DR-...: Processing / Ready / Released / Rejected | the Registrar moves the request |
| Student | `<office>` cleared you / `<office>` left a note / Your clearance is approved | an office clears, leaves remarks, or the Registrar gives the final approval |
| Student | A hold was placed / lifted | a department places or lifts a hold |
| Student | A new grade was posted / A grade was updated | the Registrar encodes or changes a grade |
| Registrar | New application / New enrollment to review / New document request | a student applies, submits, or requests |
| Registrar | A clearance is ready for final approval | the last office clears |
| Department head, Cashier | Clearance item waiting | a student requests clearance (Cashier for the Financial office) |
| Admin | nothing yet | the inbox works, no event sends to Admin |

Not included on purpose: charges and payments, login events.

## How it works

- Notifications are written by the database itself, by triggers on the tables where things happen (queue tickets, enrollments,
  document requests, clearance items and clearances, holds, grades, applications). The app never has to remember to send one.
- **A notification problem can never block the real action.** Every helper and every trigger catches its own errors and only writes a
  server warning, so accepting an application or approving an enrollment succeeds even if the notification could not be written.
- **Privacy:** a person reads only their own notifications (row-level security plus functions that only return the caller's rows).
  Nobody can write, edit or delete a notification through the API; the only change a user can make is marking their own as read.
  The text uses names only for the Registrar and office staff, who already see them.
- The kind of a notification is a short code (for example `queue_turn`), not a fixed list, so a new kind needs no database change; the
  page picks an icon from the code's prefix and falls back to a plain bell.

## Known limits (written up honestly)

- A failing notification is silent for the user (it only becomes a warning in the database log).
- A flood of junk applications writes one notification per Registrar for each application (the application flood valve limits it).
- Older test files that compare a table's full trigger list need their expected lists updated once this is live (listed in the testing plan).
- Retention is proposed (read ones after 90 days, everything after 12 months) and not automatic.
