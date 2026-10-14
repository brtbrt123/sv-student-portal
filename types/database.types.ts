export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

/**
 * Database types for the Centralized Student Portal and Automated Clearance System.
 *
 * Mirrors ERD v3 (docs/diagrams/ERD_detailed.svg): 23 tables, 37 foreign keys
 * (36 inside `public` + `profiles.profile_id -> auth.users.id`) and 4 views.
 *
 * Shape is identical to the output of `supabase gen types typescript`, so this
 * file can be overwritten by the real generator at any time:
 *
 *   npx supabase gen types typescript --project-id <PROJECT_REF> --schema public > types/database.types.ts
 *
 * NOTE: the 4 views are defined in docs/database/views.sql (the state after
 * docs/database/views_extend.sql, run on the live project on 2026-10-10) and their columns
 * here match those definitions (checked by reading). This file was written by hand, not
 * produced by `supabase gen types`; regenerate it from the live project to confirm.
 */
export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.1"
  }
  public: {
    Tables: {
      academic_holds: {
        Row: {
          hold_id: number
          student_id: string
          department_id: number
          reason: string
          placed_by: string
          placed_at: string
          lifted_by: string | null
          lifted_at: string | null
        }
        Insert: {
          hold_id?: number
          student_id: string
          department_id: number
          reason: string
          placed_by: string
          placed_at?: string
          lifted_by?: string | null
          lifted_at?: string | null
        }
        Update: {
          hold_id?: number
          student_id?: string
          department_id?: number
          reason?: string
          placed_by?: string
          placed_at?: string
          lifted_by?: string | null
          lifted_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "academic_holds_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "academic_holds_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["department_id"]
          },
          {
            foreignKeyName: "academic_holds_placed_by_fkey"
            columns: ["placed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_id"]
          },
          {
            foreignKeyName: "academic_holds_lifted_by_fkey"
            columns: ["lifted_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_id"]
          },
        ]
      }
      audit_logs: {
        Row: {
          log_id: number
          actor_id: string | null
          action: string
          table_name: string
          record_id: string
          old_data: Json | null
          new_data: Json | null
          created_at: string
        }
        Insert: {
          log_id?: number
          actor_id?: string | null
          action: string
          table_name: string
          record_id: string
          old_data?: Json | null
          new_data?: Json | null
          created_at?: string
        }
        Update: {
          log_id?: number
          actor_id?: string | null
          action?: string
          table_name?: string
          record_id?: string
          old_data?: Json | null
          new_data?: Json | null
          created_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "audit_logs_actor_id_fkey"
            columns: ["actor_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_id"]
          },
        ]
      }
      charges: {
        Row: {
          charge_id: number
          student_id: string
          term_id: number
          fee_type_id: number
          amount: number
          due_date: string | null
          status: string
        }
        Insert: {
          charge_id?: number
          student_id: string
          term_id: number
          fee_type_id: number
          amount: number
          due_date?: string | null
          status?: string
        }
        Update: {
          charge_id?: number
          student_id?: string
          term_id?: number
          fee_type_id?: number
          amount?: number
          due_date?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "charges_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "charges_term_id_fkey"
            columns: ["term_id"]
            isOneToOne: false
            referencedRelation: "terms"
            referencedColumns: ["term_id"]
          },
          {
            foreignKeyName: "charges_fee_type_id_fkey"
            columns: ["fee_type_id"]
            isOneToOne: false
            referencedRelation: "fee_types"
            referencedColumns: ["fee_type_id"]
          },
        ]
      }
      clearance_items: {
        Row: {
          clearance_item_id: number
          clearance_id: number
          department_id: number
          cleared_at: string | null
          cleared_by: string | null
          remarks: string | null
        }
        Insert: {
          clearance_item_id?: number
          clearance_id: number
          department_id: number
          cleared_at?: string | null
          cleared_by?: string | null
          remarks?: string | null
        }
        Update: {
          clearance_item_id?: number
          clearance_id?: number
          department_id?: number
          cleared_at?: string | null
          cleared_by?: string | null
          remarks?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "clearance_items_clearance_id_fkey"
            columns: ["clearance_id"]
            isOneToOne: false
            referencedRelation: "clearances"
            referencedColumns: ["clearance_id"]
          },
          {
            foreignKeyName: "clearance_items_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["department_id"]
          },
          {
            foreignKeyName: "clearance_items_cleared_by_fkey"
            columns: ["cleared_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_id"]
          },
        ]
      }
      clearances: {
        Row: {
          clearance_id: number
          student_id: string
          term_id: number
          created_at: string
          approved_by: string | null
          approved_at: string | null
        }
        Insert: {
          clearance_id?: number
          student_id: string
          term_id: number
          created_at?: string
          approved_by?: string | null
          approved_at?: string | null
        }
        Update: {
          clearance_id?: number
          student_id?: string
          term_id?: number
          created_at?: string
          approved_by?: string | null
          approved_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "clearances_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "clearances_term_id_fkey"
            columns: ["term_id"]
            isOneToOne: false
            referencedRelation: "terms"
            referencedColumns: ["term_id"]
          },
          {
            foreignKeyName: "clearances_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_id"]
          },
        ]
      }
      department_staff: {
        Row: {
          profile_id: string
          department_id: number
        }
        Insert: {
          profile_id: string
          department_id: number
        }
        Update: {
          profile_id?: string
          department_id?: number
        }
        Relationships: [
          {
            foreignKeyName: "department_staff_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["profile_id"]
          },
          {
            foreignKeyName: "department_staff_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["department_id"]
          },
        ]
      }
      departments: {
        Row: {
          department_id: number
          code: string
          name: string
          department_type: string
        }
        Insert: {
          department_id?: number
          code: string
          name: string
          department_type: string
        }
        Update: {
          department_id?: number
          code?: string
          name?: string
          department_type?: string
        }
        Relationships: []
      }
      document_requests: {
        Row: {
          request_id: number
          ticket_number: string
          student_id: string
          document_type_id: number
          purpose: string
          copies: number
          status: string
          requested_at: string
          processed_by: string | null
          processed_at: string | null
          remarks: string | null
        }
        Insert: {
          request_id?: number
          ticket_number?: string
          student_id: string
          document_type_id: number
          purpose: string
          copies?: number
          status?: string
          requested_at?: string
          processed_by?: string | null
          processed_at?: string | null
          remarks?: string | null
        }
        Update: {
          request_id?: number
          ticket_number?: string
          student_id?: string
          document_type_id?: number
          purpose?: string
          copies?: number
          status?: string
          requested_at?: string
          processed_by?: string | null
          processed_at?: string | null
          remarks?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "document_requests_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "document_requests_document_type_id_fkey"
            columns: ["document_type_id"]
            isOneToOne: false
            referencedRelation: "document_types"
            referencedColumns: ["document_type_id"]
          },
          {
            foreignKeyName: "document_requests_processed_by_fkey"
            columns: ["processed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_id"]
          },
        ]
      }
      document_types: {
        Row: {
          document_type_id: number
          name: string
        }
        Insert: {
          document_type_id?: number
          name: string
        }
        Update: {
          document_type_id?: number
          name?: string
        }
        Relationships: []
      }
      enrollment_items: {
        Row: {
          enrollment_item_id: number
          enrollment_id: number
          section_id: number
        }
        Insert: {
          enrollment_item_id?: number
          enrollment_id: number
          section_id: number
        }
        Update: {
          enrollment_item_id?: number
          enrollment_id?: number
          section_id?: number
        }
        Relationships: [
          {
            foreignKeyName: "enrollment_items_enrollment_id_fkey"
            columns: ["enrollment_id"]
            isOneToOne: false
            referencedRelation: "enrollments"
            referencedColumns: ["enrollment_id"]
          },
          {
            foreignKeyName: "enrollment_items_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "sections"
            referencedColumns: ["section_id"]
          },
        ]
      }
      enrollments: {
        Row: {
          enrollment_id: number
          student_id: string
          term_id: number
          year_level: number
          status: string
          submitted_at: string
          reviewed_by: string | null
          reviewed_at: string | null
          remarks: string | null
        }
        Insert: {
          enrollment_id?: number
          student_id: string
          term_id: number
          year_level: number
          status?: string
          submitted_at?: string
          reviewed_by?: string | null
          reviewed_at?: string | null
          remarks?: string | null
        }
        Update: {
          enrollment_id?: number
          student_id?: string
          term_id?: number
          year_level?: number
          status?: string
          submitted_at?: string
          reviewed_by?: string | null
          reviewed_at?: string | null
          remarks?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "enrollments_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "enrollments_term_id_fkey"
            columns: ["term_id"]
            isOneToOne: false
            referencedRelation: "terms"
            referencedColumns: ["term_id"]
          },
          {
            foreignKeyName: "enrollments_reviewed_by_fkey"
            columns: ["reviewed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_id"]
          },
        ]
      }
      fee_types: {
        Row: {
          fee_type_id: number
          name: string
        }
        Insert: {
          fee_type_id?: number
          name: string
        }
        Update: {
          fee_type_id?: number
          name?: string
        }
        Relationships: []
      }
      grade_scale: {
        Row: {
          grade_code: string
          numeric_value: number | null
          is_passing: boolean
          description: string
        }
        Insert: {
          grade_code: string
          numeric_value?: number | null
          is_passing: boolean
          description: string
        }
        Update: {
          grade_code?: string
          numeric_value?: number | null
          is_passing?: boolean
          description?: string
        }
        Relationships: []
      }
      grades: {
        Row: {
          grade_id: number
          enrollment_item_id: number
          grade_code: string
          encoded_by: string
          encoded_at: string
        }
        Insert: {
          grade_id?: number
          enrollment_item_id: number
          grade_code: string
          encoded_by: string
          encoded_at?: string
        }
        Update: {
          grade_id?: number
          enrollment_item_id?: number
          grade_code?: string
          encoded_by?: string
          encoded_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "grades_enrollment_item_id_fkey"
            columns: ["enrollment_item_id"]
            isOneToOne: true
            referencedRelation: "enrollment_items"
            referencedColumns: ["enrollment_item_id"]
          },
          {
            foreignKeyName: "grades_grade_code_fkey"
            columns: ["grade_code"]
            isOneToOne: false
            referencedRelation: "grade_scale"
            referencedColumns: ["grade_code"]
          },
          {
            foreignKeyName: "grades_encoded_by_fkey"
            columns: ["encoded_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_id"]
          },
        ]
      }
      login_attempts: {
        Row: {
          attempt_id: number
          email: string
          ip_address: unknown | null
          was_successful: boolean
          attempted_at: string
        }
        Insert: {
          attempt_id?: number
          email: string
          ip_address?: unknown | null
          was_successful: boolean
          attempted_at?: string
        }
        Update: {
          attempt_id?: number
          email?: string
          ip_address?: unknown | null
          was_successful?: boolean
          attempted_at?: string
        }
        Relationships: []
      }
      payments: {
        Row: {
          payment_id: number
          charge_id: number
          amount_paid: number
          paid_at: string
          receipt_number: string
          recorded_by: string
        }
        Insert: {
          payment_id?: number
          charge_id: number
          amount_paid: number
          paid_at?: string
          receipt_number?: string
          recorded_by: string
        }
        Update: {
          payment_id?: number
          charge_id?: number
          amount_paid?: number
          paid_at?: string
          receipt_number?: string
          recorded_by?: string
        }
        Relationships: [
          {
            foreignKeyName: "payments_charge_id_fkey"
            columns: ["charge_id"]
            isOneToOne: false
            referencedRelation: "charges"
            referencedColumns: ["charge_id"]
          },
          {
            foreignKeyName: "payments_recorded_by_fkey"
            columns: ["recorded_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_id"]
          },
        ]
      }
      profiles: {
        Row: {
          profile_id: string
          role_id: number
          first_name: string
          last_name: string
          email: string
          is_active: boolean
          created_at: string
        }
        Insert: {
          profile_id: string
          role_id: number
          first_name: string
          last_name: string
          email: string
          is_active?: boolean
          created_at?: string
        }
        Update: {
          profile_id?: string
          role_id?: number
          first_name?: string
          last_name?: string
          email?: string
          is_active?: boolean
          created_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "profiles_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["role_id"]
          },
        ]
      }
      programs: {
        Row: {
          program_id: number
          department_id: number
          code: string
          name: string
        }
        Insert: {
          program_id?: number
          department_id: number
          code: string
          name: string
        }
        Update: {
          program_id?: number
          department_id?: number
          code?: string
          name?: string
        }
        Relationships: [
          {
            foreignKeyName: "programs_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["department_id"]
          },
        ]
      }
      roles: {
        Row: {
          role_id: number
          role_name: string
        }
        Insert: {
          role_id?: number
          role_name: string
        }
        Update: {
          role_id?: number
          role_name?: string
        }
        Relationships: []
      }
      sections: {
        Row: {
          section_id: number
          subject_id: number
          term_id: number
          section_code: string
          schedule: string | null
          capacity: number
        }
        Insert: {
          section_id?: number
          subject_id: number
          term_id: number
          section_code: string
          schedule?: string | null
          capacity: number
        }
        Update: {
          section_id?: number
          subject_id?: number
          term_id?: number
          section_code?: string
          schedule?: string | null
          capacity?: number
        }
        Relationships: [
          {
            foreignKeyName: "sections_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["subject_id"]
          },
          {
            foreignKeyName: "sections_term_id_fkey"
            columns: ["term_id"]
            isOneToOne: false
            referencedRelation: "terms"
            referencedColumns: ["term_id"]
          },
        ]
      }
      students: {
        Row: {
          student_id: string
          student_number: string
          program_id: number
        }
        Insert: {
          student_id: string
          student_number: string
          program_id: number
        }
        Update: {
          student_id?: string
          student_number?: string
          program_id?: number
        }
        Relationships: [
          {
            foreignKeyName: "students_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["profile_id"]
          },
          {
            foreignKeyName: "students_program_id_fkey"
            columns: ["program_id"]
            isOneToOne: false
            referencedRelation: "programs"
            referencedColumns: ["program_id"]
          },
        ]
      }
      subjects: {
        Row: {
          subject_id: number
          department_id: number
          code: string
          title: string
          units: number
        }
        Insert: {
          subject_id?: number
          department_id: number
          code: string
          title: string
          units: number
        }
        Update: {
          subject_id?: number
          department_id?: number
          code?: string
          title?: string
          units?: number
        }
        Relationships: [
          {
            foreignKeyName: "subjects_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["department_id"]
          },
        ]
      }
      terms: {
        Row: {
          term_id: number
          school_year: string
          semester: string
          start_date: string
          end_date: string
          is_current: boolean
        }
        Insert: {
          term_id?: number
          school_year: string
          semester: string
          start_date: string
          end_date: string
          is_current?: boolean
        }
        Update: {
          term_id?: number
          school_year?: string
          semester?: string
          start_date?: string
          end_date?: string
          is_current?: boolean
        }
        Relationships: []
      }
    }
    Views: {
      v_active_holds: {
        Row: {
          hold_id: number | null
          student_id: string | null
          department_id: number | null
          reason: string | null
          placed_by: string | null
          placed_at: string | null
        }
        Relationships: []
      }
      v_clearance_items: {
        Row: {
          clearance_item_id: number | null
          clearance_id: number | null
          student_id: string | null
          term_id: number | null
          department_id: number | null
          department_name: string | null
          department_type: string | null
          cleared_at: string | null
          cleared_by: string | null
          remarks: string | null
          status: string | null
        }
        Relationships: []
      }
      v_clearances: {
        Row: {
          clearance_id: number | null
          student_id: string | null
          term_id: number | null
          created_at: string | null
          approved_by: string | null
          approved_at: string | null
          total_items: number | null
          cleared_items: number | null
          status: string | null
        }
        Relationships: []
      }
      v_grades: {
        Row: {
          grade_id: number | null
          enrollment_item_id: number | null
          enrollment_id: number | null
          student_id: string | null
          term_id: number | null
          section_id: number | null
          subject_id: number | null
          subject_code: string | null
          subject_title: string | null
          units: number | null
          grade_code: string | null
          numeric_value: number | null
          is_passing: boolean | null
          encoded_by: string | null
          encoded_at: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      check_login_lockout: {
        Args: { p_email: string }
        Returns: { locked: boolean; seconds_remaining: number }[]
      }
      record_login_attempt: {
        Args: { p_email: string; p_success: boolean; p_ip?: string | null }
        Returns: undefined
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DefaultSchema = Database[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof Omit<Database, "__InternalSupabase"> },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof Omit<Database, "__InternalSupabase">
  }
    ? keyof (Omit<Database, "__InternalSupabase">[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        Omit<Database, "__InternalSupabase">[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof Omit<Database, "__InternalSupabase">
}
  ? (Omit<Database, "__InternalSupabase">[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      Omit<Database, "__InternalSupabase">[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof Omit<Database, "__InternalSupabase"> },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof Omit<Database, "__InternalSupabase">
  }
    ? keyof Omit<Database, "__InternalSupabase">[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof Omit<Database, "__InternalSupabase">
}
  ? Omit<Database, "__InternalSupabase">[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof Omit<Database, "__InternalSupabase"> },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof Omit<Database, "__InternalSupabase">
  }
    ? keyof Omit<Database, "__InternalSupabase">[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof Omit<Database, "__InternalSupabase">
}
  ? Omit<Database, "__InternalSupabase">[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof Omit<Database, "__InternalSupabase"> },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof Omit<Database, "__InternalSupabase">
  }
    ? keyof Omit<Database, "__InternalSupabase">[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof Omit<Database, "__InternalSupabase">
}
  ? Omit<Database, "__InternalSupabase">[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const