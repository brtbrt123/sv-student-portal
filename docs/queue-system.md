# Virtual queue for the Registrar window (physical queuing for enrollment)

Pain point from the professor's list: physical queuing for enrollment. After an application is accepted the student must go to
the Registrar in person. Many arrive at once, the line is disorganised and people cut in. This feature gives every student a
ticket, shows them their place in the line from their phone, and gives the Registrar a screen to run the line.

Built 2026-10-13. Database: `docs/database/queue_rules.sql`. Tests: `docs/testing-plan.md` (UT-50 to UT-66, TC-139 to TC-166,
Q-01 to Q-09, V-6 and V-7).

## The flow

1. **Accepted.** The student gets the account email (existing flow) and signs in to the portal.
2. **The queue pass.** On the Enrollment page a student whose enrollment is not yet Approved sees "Physical enrollment at the
   Registrar" with a QR code that changes every 15 seconds.
3. **At the school.** The Registrar's queue desk reads the QR with a USB barcode scanner (it types the code like a keyboard) or
   with the camera of the device. The code is checked on the server and **the ticket is issued in the same step** (changed
   2026-10-14: there is no Approve button any more). The result stays on screen for 7 seconds with the ticket number, the
   student's name, number and program, and how many are ahead; the camera is locked for those seconds so one scan can never
   become two. A student who already has a ticket in that line is told so and gets no second one. The Registrar checks the
   student's ID against the name **at the window**, when the number is called (the name is shown again there).
4. **Ticket.** A scan issues a ticket with a **random 7-digit code** such as `#8503599`. The line order is kept separately
   (`ticket_number`, never shown), so nobody can guess or count the line from the codes.
5. **The student's tracker.** The page shows the ticket, "You are 25th in line" (or "You are next"), a drawn line from the window to the
   back (the people ahead, you, the people behind), the people ahead, the last number called, and an estimated wait of 3 to 5
   minutes for each person ahead (`lib/queue/line.ts`; a fixed range, not measured). It refreshes every 5 to 10 seconds. When the Registrar presses **Call next** the page turns green:
   "It is your turn. Go to Window 3 now."
   On a phone the Registrar's queue page has two tabs, **Scan** and **Line** (with the number of people in the line), so the camera does
   not push Call next off the screen. From a laptop screen up both sit side by side.
6. **At the window.** The Registrar sees the name again, then marks the ticket **Done** or **No-show**. A student can leave the
   queue before being called.

**Hold (2026-10-14, `docs/database/queue_hold.sql`, live; rehearsal TC-199..217 passed 19 of 19).** A student can press **Hold my place**
while Waiting (bathroom, emergency). The ticket becomes `Held`: Call next skips it, so the people behind are served. **I'm back**
puts it back to Waiting with the same number, so the student is next. Holding and unholding at once changes nothing (the order is
the ticket number), so a hold cannot be used to jump the line. A hold lasts 15 minutes (`private.queue_hold_limit()`); after
that unhold is refused and the Registrar can mark the ticket No-show (or the student cancels). **Cancel ticket** has a confirm step.
Expired holds do not end by themselves and keep blocking a new ticket for that student and service that day until No-show or cancel.

The same tables serve a second service, `Documents` (claiming a document). It is wired too: a student with an open document
request (Pending, Processing or Ready) sees the same rotating QR on **Document requests** and gets a ticket from the Registrar
the same way. The Registrar's Queue page has a switch between the **Enrollment** and **Documents** lines (`?service=Documents`),
each with its own numbers and its own Call next. No database change was needed. Note: the scan card's "already queued" note
looks at Enrollment only; a second Documents ticket is still refused by the database ("already queued").

## How it is built

- **QR code** (`lib/queue/qr-token.ts`): `CUQ1.<student id>.<15-second window>.<signature>`. The signature is an HMAC-SHA256 with a
  server-only secret (`QUEUE_QR_SECRET`, at least 32 characters, never sent to the browser). A code works in its own window and
  the next one, so a screenshot is useless after 30 seconds at most. It is not an RFC 6238 TOTP: the QR must carry the student id,
  and generating a TOTP in the browser would expose the secret.
- **Database** (`queue_rules.sql`): `queue_services`, `queue_tickets`, `queue_counters` and seven functions (issue a ticket,
  call next, finish, cancel my ticket, my status, staff list, student card). Nobody writes the tables directly: every change goes
  through a function that checks the caller's role. Illegal status changes are blocked by a trigger (Waiting to Serving or
  Cancelled; Serving to Done or No-show; the rest are final) and every ticket change is written to the audit log.
- **Privacy:** a student sees only their own ticket and counts. Names are visible only to the Registrar. The scan only looks the
  student up and issues the ticket; the person is checked against their ID at the window.
- **No Realtime:** a student cannot see other tickets (privacy rules), so Realtime would only say "something changed" and the page
  would still have to re-count. Refreshing every 5 to 10 seconds gives the same result without extra production configuration.

## Residual risks (accepted, written in the paper)

- **Proxy queuing.** Someone holding a student's phone can now get a ticket without anyone comparing a face first (the Approve
  step was removed on 2026-10-14 so a scan is one step). The check moved to the window: the name is shown again when the number
  is called, the Registrar compares it with the ID and the person, and marks No-show if it does not match. A Registrar cannot void
  a Waiting ticket (only the student can cancel it), so a wrong ticket stays in the line until it is called. A student **photo** on the card would help. It needs a source (an upload on the
  application form), consent and private storage; a placeholder is in the SQL header and on the screen.
- **Random codes do not stop trading by themselves.** The ID check at the desk and the name shown again at the window do.
- **Hardware.** A USB barcode scanner must be a 2D imager that can read a phone screen; many cheap laser scanners cannot.
- **Stale tickets.** Tickets left open at the end of a day stay as they are (they do not block the next day). A daily close-out and
  a 12-month retention are proposed in the header of `queue_rules.sql`; nothing runs automatically.

## To go live

- Add `QUEUE_QR_SECRET` to the Vercel project (Production) before `dev` is merged into `main`.
- Not built yet: the visit day in the acceptance email, the student photo, the camera and scanner test on real hardware.
