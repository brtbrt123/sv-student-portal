
export const MAX_LOGIN_NAME = 254 // same limit as the database (max_email_length)
export const MAX_LOGIN_PASSWORD = 1024

// ASCII and Unicode control characters (the same class the database rejects with [[:cntrl:]]).
const CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f]/

export function loginInputIsAcceptable(typed: string, password: string): boolean {
  if (typed.length === 0 || typed.length > MAX_LOGIN_NAME) return false
  if (password.length === 0 || password.length > MAX_LOGIN_PASSWORD) return false
  if (CONTROL_CHARS.test(typed)) return false
  return true
}
