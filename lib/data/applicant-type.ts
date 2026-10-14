import 'server-only'
import { getAdminClientFor } from '@/lib/supabase/admin'

// Whether the signed-in student's subjects are set by their program: true for a student who applied as
// a NEW student (the first-year subjects are assigned when the Registrar accepts the application and a
// Registrar drops a subject on request), false for a transferee and for a student with no application
// (the seed students), who pick their own sections.
//
// The application table is private (only the Registrar reads it), so this reads ONE row, the signed-in
// student's own application, with the admin client. getAdminClientFor('Student') checks the session
// first. It never throws: any failure means "not locked", which is the old pick-your-own behaviour.
export async function isSubjectSetByProgram(): Promise<boolean> {
  try {
    const ctx = await getAdminClientFor('Student')
    if (!ctx) return false
    const { data, error } = await ctx.admin
      .from('applications')
      .select('applicant_type')
      .eq('student_id', ctx.profile.id)
      .limit(1)
      .maybeSingle()
    if (error || !data) return false
    return (data as { applicant_type: string | null }).applicant_type !== 'Transferee'
  } catch {
    return false
  }
}
