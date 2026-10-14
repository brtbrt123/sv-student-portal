'use server'

import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getCurrentProfile } from '@/lib/auth/session'
import { ROLE_HOME } from '@/lib/auth/roles'
import { passwordProblem } from '@/lib/auth/password-policy'

export type SetPasswordState = { error: string | null }

const GENERIC = 'We could not save your password. Please try again in a few minutes.'

// Saves the new password for the signed-in user (the session comes from the /auth/confirm link).
// The password is never logged or sent back to the page.
export async function setPassword(_prev: SetPasswordState, formData: FormData): Promise<SetPasswordState> {
  void _prev
  const password = String(formData.get('password') ?? '')
  const confirm = String(formData.get('confirm') ?? '')

  // 8 to 72 characters with a capital letter, a number and a special character (lib/auth/password-policy.ts).
  const problem = passwordProblem(password)
  if (problem) return { error: problem }
  if (password !== confirm) return { error: 'The two passwords do not match.' }

  let signedOut = false
  try {
    const supabase = await createClient()
    const { data: userData } = await supabase.auth.getUser()
    const user = userData.user
    if (!user) {
      signedOut = true
    } else {
      // The student ID is the part of the sign-in address before the @ (for example 2026-0001).
      const studentId = (user.email ?? '').split('@')[0].toLowerCase()
      if (studentId && password.toLowerCase() === studentId) {
        return { error: 'Your password cannot be your student ID.' }
      }

      const { error } = await supabase.auth.updateUser({ password })
      if (error) {
        const code = (error as { code?: string }).code
        if (code === 'same_password') return { error: 'Choose a password you have not used before.' }
        if (code === 'weak_password') return { error: 'That password is too easy to guess. Try a different one with more letters, numbers and symbols.' }
        return { error: GENERIC }
      }
    }
  } catch {
    return { error: GENERIC }
  }

  if (signedOut) redirect('/login?notice=link-expired')

  const profile = await getCurrentProfile()
  redirect(profile ? ROLE_HOME[profile.role] : '/login')
}
