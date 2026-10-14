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
