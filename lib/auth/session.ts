import { cache } from 'react'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { isRoleName, ROLE_HOME, type RoleName } from '@/lib/auth/roles'
import { getUnreadCount } from '@/lib/data/notifications'

export type CurrentProfile = {
  id: string
  email: string
  firstName: string
  lastName: string
  role: RoleName
}

// Returns the signed-in user's profile and role, or null when signed out,
// deactivated, or without a profile row. Wrapped in cache(): within one request (page, layout, shell)
// the two database round trips are made once, however many parts of the page ask.
export const getCurrentProfile = cache(async function getCurrentProfile(): Promise<CurrentProfile | null> {
  const supabase = await createClient()
  const { data: userData } = await supabase.auth.getUser()
  const user = userData.user
  if (!user) return null

  const { data: profile } = await supabase
    .from('profiles')
    .select('profile_id, first_name, last_name, email, is_active, roles(role_name)')
    .eq('profile_id', user.id)
    .single()

  // roles is a many-to-one join; supabase-js may type it as object or array
  const roleRow = Array.isArray(profile?.roles) ? profile?.roles[0] : profile?.roles
  const roleName = roleRow?.role_name
  if (!profile || !profile.is_active || !isRoleName(roleName)) return null

  return {
    id: profile.profile_id,
    email: profile.email,
    firstName: profile.first_name,
    lastName: profile.last_name,
    role: roleName,
  }
})

// Call at the top of a module page. Sends signed-out users to /login and
// users with another role to their own dashboard.
export async function requireRole(role: RoleName): Promise<CurrentProfile> {
  const profile = await getCurrentProfile()
  if (!profile) redirect('/login')
  if (profile.role !== role) redirect(ROLE_HOME[profile.role])
  // Start the sidebar's unread count now so it runs while the page loads its own data; DashboardShell
  // awaits the same cached call later. (getUnreadCount never throws.)
  void getUnreadCount()
  return profile
}
