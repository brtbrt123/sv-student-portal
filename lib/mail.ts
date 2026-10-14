import 'server-only'

// Tiny mail adapter over the Resend REST API (POST https://api.resend.com/emails), no extra package.
// Needs env RESEND_API_KEY (server only) and MAIL_FROM (e.g. "Cabuyao University <no-reply@your-domain>").
// Plain-text emails only. On failure it throws a plain Error that never contains the key, the
// recipient or the provider's response body, so callers can show a generic message safely.

export type MailMessage = { to: string; subject: string; text: string }

const RESEND_URL = 'https://api.resend.com/emails'
const TIMEOUT_MS = 10_000

export async function sendMail({ to, subject, text }: MailMessage): Promise<void> {
  const apiKey = process.env.RESEND_API_KEY
  const from = process.env.MAIL_FROM
  if (!apiKey || !from) throw new Error('Email is not configured on the server.')

  let res: Response
  try {
    res = await fetch(RESEND_URL, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from, to: [to], subject, text }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
      cache: 'no-store',
    })
  } catch {
    throw new Error('The email service could not be reached.')
  }
  if (!res.ok) throw new Error(`The email service refused the message (HTTP ${res.status}).`)
}

const SCHOOL = 'Cabuyao University Student Portal'

// Acceptance email: the student ID and the one-time set-password link. Never contains a password.
export function acceptanceEmail(firstName: string, studentNumber: string, link: string): Omit<MailMessage, 'to'> {
  return {
    subject: `Welcome to ${SCHOOL}: your student ID`,
    text: [
      `Hi ${firstName},`,
      '',
      'Good news: your application has been accepted. Welcome!',
      '',
      `Your student ID is: ${studentNumber}`,
      '',
      'To start using the portal, set your password with this link:',
      link,
      '',
      'This link works only once and expires after a short time. If it has expired or was already used,',
      "contact the Registrar's Office and ask for a new one.",
      '',
      'After you set your password, sign in to the portal with your student ID and that password.',
      '',
      'Next step: your physical enrollment at the school.',
      'When you arrive on campus, sign in to the portal, open Enrollment, and show the QR code on that page to the Registrar.',
      'You will get a queue number, and you can follow your place in line from your phone.',
      'Please bring a valid ID or your previous school ID. The Registrar will check it against your name on the screen.',
      '',
      'If you did not apply, you can ignore this email.',
      '',
      `${SCHOOL}`,
      "Registrar's Office",
    ].join('\n'),
  }
}

// Rejection notice: no account details, only the decision and the Registrar's remarks.
export function rejectionEmail(firstName: string, remarks: string): Omit<MailMessage, 'to'> {
  return {
    subject: `${SCHOOL}: update on your application`,
    text: [
      `Hi ${firstName},`,
      '',
      'Thank you for applying. After review, we are not able to accept your application at this time.',
      '',
      `Note from the Registrar: ${remarks}`,
      '',
      "If you have questions, please contact the Registrar's Office.",
      '',
      `${SCHOOL}`,
      "Registrar's Office",
    ].join('\n'),
  }
}
