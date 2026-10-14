import 'server-only'
import { QR_MIN_SECRET_LENGTH } from '@/lib/queue/qr-token'

// The signing secret of the rotating queue QR. Server-only: it is never sent to the browser and never
// placed in the repository. Set QUEUE_QR_SECRET (at least 32 random characters) in .env.local and in the
// Vercel project. Returns null when it is missing or too short, so the queue says "not configured"
// instead of signing codes with a weak secret.
export function getQueueSecret(): string | null {
  const secret = process.env.QUEUE_QR_SECRET?.trim()
  return secret && secret.length >= QR_MIN_SECRET_LENGTH ? secret : null
}
