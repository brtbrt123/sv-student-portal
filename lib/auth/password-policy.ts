// The password rules for choosing a password (the set-password page). One place, used by the server action (which
// decides) and by the form (which only shows the checklist as the person types).
//   - 8 to 72 characters (72 is the most the password hashing keeps),
//   - at least one capital letter, one number and one special character.
// A special character is anything that is not a letter, a number or a space. Signing in does NOT check these rules:
// a password chosen earlier under the old rule (10 characters) must keep working.

export const PASSWORD_MIN_LENGTH = 8
export const PASSWORD_MAX_LENGTH = 72

export type PasswordRuleId = 'length' | 'upper' | 'digit' | 'special'
export type PasswordRule = { id: PasswordRuleId; label: string; ok: boolean }

const UPPER = /\p{Lu}/u
const DIGIT = /\p{Nd}/u
const SPECIAL = /[^\p{L}\p{N}\s]/u

// The four rules, each with whether this password meets it (for the checklist).
export function passwordRules(password: string): PasswordRule[] {
  return [
    { id: 'length', label: `At least ${PASSWORD_MIN_LENGTH} characters`, ok: password.length >= PASSWORD_MIN_LENGTH },
    { id: 'upper', label: 'One capital letter', ok: UPPER.test(password) },
    { id: 'digit', label: 'One number', ok: DIGIT.test(password) },
    { id: 'special', label: 'One special character (for example ! ? # @)', ok: SPECIAL.test(password) },
  ]
}

const PROBLEM: Record<PasswordRuleId, string> = {
  length: `Use at least ${PASSWORD_MIN_LENGTH} characters.`,
  upper: 'Add at least one capital letter.',
  digit: 'Add at least one number.',
  special: 'Add at least one special character, such as ! ? # or @.',
}

// The first rule the password breaks, as a plain sentence, or null when it is acceptable.
export function passwordProblem(password: string): string | null {
  if (password.length > PASSWORD_MAX_LENGTH) return `Use ${PASSWORD_MAX_LENGTH} characters at most.`
  const broken = passwordRules(password).find((r) => !r.ok)
  return broken ? PROBLEM[broken.id] : null
}

// ---- Strength meter (shown only as a guide; the rules above are what decide) --------------------------------------
// Level 0 = nothing typed, 1 = Weak, 2 = Fair, 3 = Good, 4 = Strong.
//   - how many of the four rules are met: 0 or 1 or 2 -> Weak, 3 -> Fair, all four -> Good;
//   - all four rules and 12 or more characters -> Strong;
//   - a password with a very common word or run in it, or only a few different characters, never gets above Weak
//     (it could meet every rule and still be easy to guess, for example "Password1!" or "Aaaaaaa1!").
export type PasswordStrength = { level: 0 | 1 | 2 | 3 | 4; label: string; note: string | null }

export const STRONG_LENGTH = 12
const COMMON_PARTS = ['password', 'qwerty', '123456', 'abcdef', 'letmein', 'welcome', 'admin', 'cabuyao', 'pnc']
const MIN_DIFFERENT_CHARACTERS = 5
const LABELS = ['', 'Weak', 'Fair', 'Good', 'Strong'] as const

export function passwordStrength(password: string): PasswordStrength {
  if (password.length === 0) return { level: 0, label: '', note: null }
  const lower = password.toLowerCase()
  if (COMMON_PARTS.some((part) => lower.includes(part))) {
    return { level: 1, label: LABELS[1], note: 'It contains a very common word or sequence.' }
  }
  if (new Set(password).size < MIN_DIFFERENT_CHARACTERS) {
    return { level: 1, label: LABELS[1], note: 'It uses too few different characters.' }
  }
  const met = passwordRules(password).filter((r) => r.ok).length
  if (met <= 2) return { level: 1, label: LABELS[1], note: null }
  if (met === 3) return { level: 2, label: LABELS[2], note: null }
  if (password.length >= STRONG_LENGTH) return { level: 4, label: LABELS[4], note: null }
  return { level: 3, label: LABELS[3], note: `Use ${STRONG_LENGTH} or more characters to make it strong.` }
}
