import 'server-only'
import { formatStudentId } from '@/lib/auth/student-id'

// Tiny mail adapter over the Resend REST API (POST https://api.resend.com/emails), no extra package.
// Needs env RESEND_API_KEY (server only) and MAIL_FROM (e.g. "Cabuyao University <no-reply@your-domain>").
// Every email carries a plain-text body and an HTML body. On failure it throws a plain Error that never
// contains the key, the recipient or the provider's response body, so callers can show a generic message safely.

export type MailMessage = { to: string; subject: string; text: string; html?: string }

const RESEND_URL = 'https://api.resend.com/emails'
const TIMEOUT_MS = 10_000

export async function sendMail({ to, subject, text, html }: MailMessage): Promise<void> {
  const apiKey = process.env.RESEND_API_KEY
  const from = process.env.MAIL_FROM
  if (!apiKey || !from) throw new Error('Email is not configured on the server.')

  let res: Response
  try {
    res = await fetch(RESEND_URL, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from, to: [to], subject, text, ...(html ? { html } : {}) }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
      cache: 'no-store',
    })
  } catch {
    throw new Error('The email service could not be reached.')
  }
  if (!res.ok) throw new Error(`The email service refused the message (HTTP ${res.status}).`)
}

const SCHOOL = 'Cabuyao University Student Portal'
const FONT = "'Segoe UI',Helvetica,Arial,sans-serif"

const escapeHtml = (v: string): string =>
  v.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;')

// The shared look of the emails: a white card on the portal's warm light canvas, inline styles only (mail
// clients ignore stylesheets) and a table layout for Outlook. `body` is HTML built from escaped values.
function layout(preheader: string, body: string): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"></head>
<body style="margin:0;padding:0;background:#f6f6f4;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;">${escapeHtml(preheader)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f6f6f4;"><tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;">
<tr><td style="padding:0 4px 16px;font-family:${FONT};font-size:15px;font-weight:800;color:#303030;"><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:#ffd85e;margin-right:8px;"></span>Cabuyao University</td></tr>
<tr><td style="background:#ffffff;border:1px solid #e6e4dc;border-radius:20px;padding:32px 28px;font-family:${FONT};font-size:15px;line-height:24px;color:#303030;">
${body}
</td></tr>
<tr><td style="padding:16px 8px 0;font-family:${FONT};font-size:12px;line-height:18px;color:#66666f;text-align:center;">${escapeHtml(SCHOOL)} &middot; Registrar&rsquo;s Office</td></tr>
</table></td></tr></table></body></html>`
}

const para = (html: string, style = ''): string => `<p style="margin:0 0 16px;${style}">${html}</p>`

const step = (n: string, title: string, detail: string): string =>
  `<tr><td valign="top" style="width:36px;padding:0 0 14px;"><span style="display:inline-block;width:26px;height:26px;border-radius:50%;background:#ffd85e;color:#18181b;font-weight:800;font-size:13px;line-height:26px;text-align:center;">${n}</span></td>` +
  `<td valign="top" style="padding:0 0 14px;"><strong>${title}</strong><br><span style="color:#66666f;">${detail}</span></td></tr>`

// Acceptance email: the student ID (8 digits) and the one-time set-password link. Never contains a password.
export function acceptanceEmail(firstName: string, studentNumber: string, link: string): Omit<MailMessage, 'to'> {
  const id = formatStudentId(studentNumber)
  const href = escapeHtml(link)

  const text = [
    `Hi ${firstName},`,
    '',
    'Good news: your application has been accepted. Welcome to Cabuyao University!',
    '',
    `Your student ID: ${id}`,
    '',
    '1. Set your password with this link (it works only once and expires after a short time):',
    link,
    '',
    '2. Sign in to the portal with your 8-digit student ID and your new password.',
    '',
    'Next: your enrollment at the school',
    'When you arrive on campus, sign in to the portal and open Queue. Show the QR code on that page to the Registrar to get your queue number, then follow your place in line from your phone.',
    'Please bring a valid ID or your previous school ID. The Registrar will check it against your name on the screen.',
    '',
    "If the link has expired or was already used, contact the Registrar's Office and ask for a new one.",
    'If you did not apply, you can ignore this email.',
    '',
    SCHOOL,
    "Registrar's Office",
  ].join('\n')

  const html = layout(
    `Welcome, ${firstName}! Your student ID is ${id}. Set your password to get started.`,
    [
      `<h1 style="margin:0 0 12px;font-size:24px;line-height:30px;font-weight:800;">Welcome, ${escapeHtml(firstName)}!</h1>`,
      para('Good news: your application has been accepted. Here is everything you need to get started.'),
      `<div style="margin:0 0 24px;padding:18px 20px;background:#fff8e1;border:1px solid #f1dfa0;border-radius:14px;text-align:center;"><div style="font-size:12px;font-weight:700;letter-spacing:.8px;text-transform:uppercase;color:#66666f;">Your student ID</div><div style="margin-top:4px;font-size:32px;line-height:40px;font-weight:800;letter-spacing:3px;">${escapeHtml(id)}</div></div>`,
      `<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="margin:0 0 8px;">${step('1', 'Set your password', 'Use the button below. The link works only once and expires after a short time.')}${step('2', 'Sign in', 'Use your 8-digit student ID and your new password.')}</table>`,
      `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 28px;"><tr><td style="background:#303030;border-radius:999px;"><a href="${href}" style="display:inline-block;padding:14px 28px;font-size:15px;font-weight:700;color:#ffffff;text-decoration:none;">Set my password</a></td></tr></table>`,
      `<div style="border-top:1px solid #e6e4dc;padding-top:24px;"><h2 style="margin:0 0 8px;font-size:17px;line-height:24px;font-weight:800;">Next: your enrollment at the school</h2>${para('When you arrive on campus, sign in to the portal and open <strong>Queue</strong>. Show the QR code to the Registrar to get your queue number, then follow your place in line from your phone.')}${para('Please bring a <strong>valid ID or your previous school ID</strong>. The Registrar will check it against your name on the screen.', 'margin-bottom:0;')}</div>`,
      `<p style="margin:24px 0 0;font-size:13px;line-height:20px;color:#66666f;">Button not working? Copy this link into your browser:<br><span style="word-break:break-all;">${href}</span><br><br>If the link has expired or was already used, contact the Registrar&rsquo;s Office for a new one. If you did not apply, you can ignore this email.</p>`,
    ].join('\n')
  )

  return { subject: `Welcome to ${SCHOOL}: your student ID`, text, html }
}

// Staff welcome email (accounts created by the Admin): the role and the one-time set-password link.
// Never contains a password. Staff sign in with this email address and the password they set.
export function staffWelcomeEmail(firstName: string, roleName: string, link: string): Omit<MailMessage, 'to'> {
  return {
    subject: `Your ${SCHOOL} staff account`,
    text: [
      `Hi ${firstName},`,
      '',
      `An account was created for you on the ${SCHOOL} with the role: ${roleName}.`,
      '',
      'To start using the portal, set your password with this link:',
      link,
      '',
      'This link works only once and expires after a short time. If it has expired or was already used,',
      'ask the portal Admin for a new one.',
      '',
      'After you set your password, sign in to the portal with this email address and that password.',
      '',
      'If you were not expecting this, you can ignore this email.',
      '',
      `${SCHOOL}`,
    ].join('\n'),
  }
}

// Rejection notice: no account details, only the decision and the Registrar's remarks.
export function rejectionEmail(firstName: string, remarks: string): Omit<MailMessage, 'to'> {
  const text = [
    `Hi ${firstName},`,
    '',
    'Thank you for applying. After review, we are not able to accept your application at this time.',
    '',
    `Note from the Registrar: ${remarks}`,
    '',
    "If you have questions, please contact the Registrar's Office.",
    '',
    SCHOOL,
    "Registrar's Office",
  ].join('\n')

  const html = layout(
    'An update on your application to Cabuyao University.',
    [
      `<h1 style="margin:0 0 12px;font-size:22px;line-height:30px;font-weight:800;">An update on your application</h1>`,
      para(`Hi ${escapeHtml(firstName)},`),
      para('Thank you for applying. After review, we are not able to accept your application at this time.'),
      `<div style="margin:0 0 16px;padding:14px 18px;background:#f6f6f4;border:1px solid #e6e4dc;border-radius:12px;"><div style="font-size:12px;font-weight:700;letter-spacing:.8px;text-transform:uppercase;color:#66666f;">Note from the Registrar</div><div style="margin-top:4px;">${escapeHtml(remarks)}</div></div>`,
      para('If you have questions, please contact the Registrar&rsquo;s Office.', 'margin-bottom:0;'),
    ].join('\n')
  )

  return { subject: `${SCHOOL}: update on your application`, text, html }
}
