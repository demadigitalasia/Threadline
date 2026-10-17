export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      app_settings: {
        Row: {
          id: number
          updated_at: string
          updated_by_profile_id: string | null
          urgency_sla_hours: number
        }
        Insert: {
          id: number
          updated_at?: string
          updated_by_profile_id?: string | null
          urgency_sla_hours?: number
        }
        Update: {
          id?: number
          updated_at?: string
          updated_by_profile_id?: string | null
          urgency_sla_hours?: number
        }
        Relationships: [
          {
            foreignKeyName: "app_settings_updated_by_profile_id_fkey"
            columns: ["updated_by_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      chat_messages: {
        Row: {
          created_at: string
          id: string
          sender_profile_id: string | null
          text: string
          thread_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          sender_profile_id?: string | null
          text: string
          thread_id: string
        }
        Update: {
          created_at?: string
          id?: string
          sender_profile_id?: string | null
          text?: string
          thread_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "chat_messages_sender_profile_id_fkey"
            columns: ["sender_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chat_messages_thread_id_fkey"
            columns: ["thread_id"]
            isOneToOne: false
            referencedRelation: "chat_threads"
            referencedColumns: ["id"]
          },
        ]
      }
      chat_threads: {
        Row: {
          created_at: string
          freelance_profile_id: string
          id: string
        }
        Insert: {
          created_at?: string
          freelance_profile_id: string
          id?: string
        }
        Update: {
          created_at?: string
          freelance_profile_id?: string
          id?: string
        }
        Relationships: [
          {
            foreignKeyName: "chat_threads_freelance_profile_id_fkey"
            columns: ["freelance_profile_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      job_events: {
        Row: {
          actor_profile_id: string | null
          created_at: string
          details: Json
          event_type: string
          from_status: Database["public"]["Enums"]["job_status"] | null
          id: string
          job_id: string
          reason: string | null
          to_status: Database["public"]["Enums"]["job_status"] | null
        }
        Insert: {
          actor_profile_id?: string | null
          created_at?: string
          details?: Json
          event_type: string
          from_status?: Database["public"]["Enums"]["job_status"] | null
          id?: string
          job_id: string
          reason?: string | null
          to_status?: Database["public"]["Enums"]["job_status"] | null
        }
        Update: {
          actor_profile_id?: string | null
          created_at?: string
          details?: Json
          event_type?: string
          from_status?: Database["public"]["Enums"]["job_status"] | null
          id?: string
          job_id?: string
          reason?: string | null
          to_status?: Database["public"]["Enums"]["job_status"] | null
        }
        Relationships: [
          {
            foreignKeyName: "job_events_actor_profile_id_fkey"
            columns: ["actor_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "job_events_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
        ]
      }
      job_files: {
        Row: {
          expired_at: string | null
          file_kind: string
          file_role: string
          id: string
          job_id: string
          name: string
          path: string
          reservation_id: string | null
          size_bytes: number
          uploaded_at: string
          uploaded_by_profile_id: string | null
        }
        Insert: {
          expired_at?: string | null
          file_kind: string
          file_role?: string
          id?: string
          job_id: string
          name: string
          path: string
          reservation_id?: string | null
          size_bytes: number
          uploaded_at?: string
          uploaded_by_profile_id?: string | null
        }
        Update: {
          expired_at?: string | null
          file_kind?: string
          file_role?: string
          id?: string
          job_id?: string
          name?: string
          path?: string
          reservation_id?: string | null
          size_bytes?: number
          uploaded_at?: string
          uploaded_by_profile_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "job_files_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "job_files_reservation_id_fkey"
            columns: ["reservation_id"]
            isOneToOne: false
            referencedRelation: "job_upload_reservations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "job_files_uploaded_by_profile_id_fkey"
            columns: ["uploaded_by_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      job_submission_files: {
        Row: {
          job_file_id: string
          submission_id: string
        }
        Insert: {
          job_file_id: string
          submission_id: string
        }
        Update: {
          job_file_id?: string
          submission_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "job_submission_files_job_file_id_fkey"
            columns: ["job_file_id"]
            isOneToOne: false
            referencedRelation: "job_files"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "job_submission_files_submission_id_fkey"
            columns: ["submission_id"]
            isOneToOne: false
            referencedRelation: "job_submissions"
            referencedColumns: ["id"]
          },
        ]
      }
      job_submissions: {
        Row: {
          decision: Database["public"]["Enums"]["submission_decision"]
          id: string
          job_id: string
          note: string | null
          submission_kind: string
          review_note: string | null
          reviewed_at: string | null
          reviewed_by_profile_id: string | null
          submitted_at: string
          submitted_by_profile_id: string | null
          version: number
        }
        Insert: {
          decision?: Database["public"]["Enums"]["submission_decision"]
          id?: string
          job_id: string
          note?: string | null
          submission_kind?: string
          review_note?: string | null
          reviewed_at?: string | null
          reviewed_by_profile_id?: string | null
          submitted_at?: string
          submitted_by_profile_id?: string | null
          version: number
        }
        Update: {
          decision?: Database["public"]["Enums"]["submission_decision"]
          id?: string
          job_id?: string
          note?: string | null
          submission_kind?: string
          review_note?: string | null
          reviewed_at?: string | null
          reviewed_by_profile_id?: string | null
          submitted_at?: string
          submitted_by_profile_id?: string | null
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "job_submissions_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "job_submissions_reviewed_by_profile_id_fkey"
            columns: ["reviewed_by_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "job_submissions_submitted_by_profile_id_fkey"
            columns: ["submitted_by_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      job_upload_reservations: {
        Row: {
          created_at: string
          expires_at: string
          id: string
          job_id: string
          profile_id: string
          size_bytes: number
          state: Database["public"]["Enums"]["upload_state"]
        }
        Insert: {
          created_at?: string
          expires_at?: string
          id?: string
          job_id: string
          profile_id: string
          size_bytes: number
          state?: Database["public"]["Enums"]["upload_state"]
        }
        Update: {
          created_at?: string
          expires_at?: string
          id?: string
          job_id?: string
          profile_id?: string
          size_bytes?: number
          state?: Database["public"]["Enums"]["upload_state"]
        }
        Relationships: [
          {
            foreignKeyName: "job_upload_reservations_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "job_upload_reservations_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      jobs: {
        Row: {
          antre_since: string | null
          approved_fee: number | null
          approved_for_profile_id: string | null
          approved_submission_id: string | null
          assignee_profile_id: string | null
          brief: string
          cancellation_reason: string | null
          cancelled_at: string | null
          cancelled_by_profile_id: string | null
          created_at: string
          current_submission_id: string | null
          deadline: string
          finished_at: string | null
          fee: number
          id: string
          jenis: Database["public"]["Enums"]["job_type"]
          priority: Database["public"]["Enums"]["job_priority"]
          qty: number
          ref: string | null
          revision: number
          status: Database["public"]["Enums"]["job_status"]
          tim: string
        }
        Insert: {
          antre_since?: string | null
          approved_fee?: number | null
          approved_for_profile_id?: string | null
          approved_submission_id?: string | null
          assignee_profile_id?: string | null
          brief?: string
          cancellation_reason?: string | null
          cancelled_at?: string | null
          cancelled_by_profile_id?: string | null
          created_at?: string
          current_submission_id?: string | null
          deadline: string
          finished_at?: string | null
          fee: number
          id: string
          jenis: Database["public"]["Enums"]["job_type"]
          priority?: Database["public"]["Enums"]["job_priority"]
          qty: number
          ref?: string | null
          revision?: number
          status?: Database["public"]["Enums"]["job_status"]
          tim: string
        }
        Update: {
          antre_since?: string | null
          approved_fee?: number | null
          approved_for_profile_id?: string | null
          approved_submission_id?: string | null
          assignee_profile_id?: string | null
          brief?: string
          cancellation_reason?: string | null
          cancelled_at?: string | null
          cancelled_by_profile_id?: string | null
          created_at?: string
          current_submission_id?: string | null
          deadline?: string
          finished_at?: string | null
          fee?: number
          id?: string
          jenis?: Database["public"]["Enums"]["job_type"]
          priority?: Database["public"]["Enums"]["job_priority"]
          qty?: number
          ref?: string | null
          revision?: number
          status?: Database["public"]["Enums"]["job_status"]
          tim?: string
        }
        Relationships: [
          {
            foreignKeyName: "jobs_approved_for_profile_id_fkey"
            columns: ["approved_for_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "jobs_approved_sub_fk"
            columns: ["approved_submission_id"]
            isOneToOne: false
            referencedRelation: "job_submissions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "jobs_assignee_profile_id_fkey"
            columns: ["assignee_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "jobs_cancelled_by_profile_id_fkey"
            columns: ["cancelled_by_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "jobs_current_sub_fk"
            columns: ["current_submission_id"]
            isOneToOne: false
            referencedRelation: "job_submissions"
            referencedColumns: ["id"]
          },
        ]
      }
      profile_role_events: {
        Row: {
          actor_label: string
          actor_profile_id: string | null
          created_at: string
          id: string
          new_role: string
          old_role: string
          new_active: boolean
          old_active: boolean
          reason: string
          target_profile_id: string
        }
        Insert: {
          actor_label: string
          actor_profile_id?: string | null
          created_at?: string
          id?: string
          new_role: string
          old_role: string
          new_active?: boolean
          old_active?: boolean
          reason: string
          target_profile_id: string
        }
        Update: {
          actor_label?: string
          actor_profile_id?: string | null
          created_at?: string
          id?: string
          new_role?: string
          old_role?: string
          new_active?: boolean
          old_active?: boolean
          reason?: string
          target_profile_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "profile_role_events_actor_profile_id_fkey"
            columns: ["actor_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "profile_role_events_target_profile_id_fkey"
            columns: ["target_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      freelancer_bank_accounts: {
        Row: {
          account_holder: string
          account_number: string
          bank_name: string
          profile_id: string
          updated_at: string
        }
        Insert: {
          account_holder: string
          account_number: string
          bank_name: string
          profile_id: string
          updated_at?: string
        }
        Update: {
          account_holder?: string
          account_number?: string
          bank_name?: string
          profile_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "freelancer_bank_accounts_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      freelancer_payment_settings: {
        Row: {
          payout_frequency: string
          payout_method: string
          profile_id: string
          updated_at: string
          updated_by_profile_id: string | null
        }
        Insert: {
          payout_frequency: string
          payout_method?: string
          profile_id: string
          updated_at?: string
          updated_by_profile_id?: string | null
        }
        Update: {
          payout_frequency?: string
          payout_method?: string
          profile_id?: string
          updated_at?: string
          updated_by_profile_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "freelancer_payment_settings_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "freelancer_payment_settings_updated_by_profile_id_fkey"
            columns: ["updated_by_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          availability_status: string
          availability_updated_at: string
          avatar_path: string | null
          id: string
          is_active: boolean
          last_seen: string
          name: string
          registration_requested_at: string
          registration_review_reason: string | null
          registration_reviewed_at: string | null
          registration_reviewed_by_profile_id: string | null
          registration_status: string
          role: string
        }
        Insert: {
          availability_status?: string
          availability_updated_at?: string
          avatar_path?: string | null
          id: string
          is_active?: boolean
          last_seen?: string
          name: string
          registration_requested_at?: string
          registration_review_reason?: string | null
          registration_reviewed_at?: string | null
          registration_reviewed_by_profile_id?: string | null
          registration_status?: string
          role?: string
        }
        Update: {
          availability_status?: string
          availability_updated_at?: string
          avatar_path?: string | null
          id?: string
          is_active?: boolean
          last_seen?: string
          name?: string
          registration_requested_at?: string
          registration_review_reason?: string | null
          registration_reviewed_at?: string | null
          registration_reviewed_by_profile_id?: string | null
          registration_status?: string
          role?: string
        }
        Relationships: [
          {
            foreignKeyName: "profiles_registration_reviewed_by_profile_id_fkey"
            columns: ["registration_reviewed_by_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      assign_job: {
        Args: {
          p_expected_rev: number
          p_job: string
          p_reason: string
          p_target: string
        }
        Returns: Json
      }
      cancel_job: {
        Args: { p_expected_rev: number; p_job: string; p_reason: string }
        Returns: Json
      }
      create_job: {
        Args: {
          p_brief: string
          p_deadline: string
          p_fee: number
          p_jenis: Database["public"]["Enums"]["job_type"]
          p_priority: Database["public"]["Enums"]["job_priority"]
          p_qty: number
          p_ref: string
          p_tim: string
        }
        Returns: Json
      }
      delete_job: { Args: { p_job: string }; Returns: Json }
      is_admin: { Args: never; Returns: boolean }
      is_finance: { Args: never; Returns: boolean }
      is_freelance: { Args: never; Returns: boolean }
      is_super_admin: { Args: never; Returns: boolean }
      is_service_role: { Args: never; Returns: boolean }
      managed_account_directory: {
        Args: never
        Returns: {
          email: string | null
          email_confirmed_at: string | null
          is_active: boolean
          last_seen: string
          name: string
          profile_id: string
          role: string
        }[]
      }
      finance_acc_recipients: {
        Args: never
        Returns: { profile_id: string; profile_name: string }[]
      }
      finance_acc_approval_times: {
        Args: never
        Returns: { job_id: string; approved_at: string }[]
      }
      finance_freelancer_payment_settings: {
        Args: never
        Returns: {
          account_holder: string | null
          account_number: string | null
          bank_name: string | null
          is_active: boolean
          payout_frequency: string
          payout_method: string
          profile_id: string
          profile_name: string
          updated_at: string | null
        }[]
      }
      finance_freelancer_bank_account: {
        Args: { p_profile: string }
        Returns: { account_holder: string; account_number: string; bank_name: string }[]
      }
      finance_monthly_payment_report: {
        Args: { p_month: string }
        Returns: {
          closing_balance: number
          earned_this_month: number
          jobs_finished_this_month: number
          opening_balance: number
          paid_this_month: number
          profile_id: string
          profile_name: string
        }[]
      }
      finance_monthly_jobs: {
        Args: { p_limit?: number; p_month: string; p_offset?: number; p_profile: string }
        Returns: {
          due_amount: number
          earned_fee: number
          finished_at: string
          job_id: string
          job_type: Database["public"]["Enums"]["job_type"]
          paid_amount: number
          team_name: string
          total_rows: number
        }[]
      }
      finance_unpaid_jobs: {
        Args: { p_limit?: number; p_offset?: number; p_profile: string }
        Returns: {
          due_amount: number
          earned_fee: number
          finished_at: string
          job_id: string
          job_type: Database["public"]["Enums"]["job_type"]
          paid_amount: number
          team_name: string
          total_rows: number
        }[]
      }
      finance_payment_history: {
        Args: { p_limit?: number; p_month: string; p_offset?: number }
        Returns: {
          allocations: Json
          account_holder: string | null
          account_number_last4: string | null
          amount: number
          bank_reference: string
          bank_name: string | null
          note: string
          paid_at: string
          payment_id: string
          proof_path: string
          recipient_name: string
          recipient_profile_id: string
          recorded_at: string
          recorded_by: string
          status: string
          total_rows: number
          void_reason: string | null
          voided_at: string | null
          voided_by: string | null
        }[]
      }
      finance_payment_audit_log: {
        Args: { p_limit?: number; p_month: string; p_offset?: number }
        Returns: {
          actor_name: string
          created_at: string
          details: Json
          event_id: string
          event_type: string
          payment_record_id: string | null
          target_name: string
          target_profile_id: string | null
          total_rows: number
        }[]
      }
      finance_log_payment_proof_view: {
        Args: { p_payment: string }
        Returns: Json
      }
      record_freelancer_payment: {
        Args: {
          p_allocations: Json
          p_bank_reference: string
          p_note: string
          p_paid_at: string
          p_proof_path: string
          p_recipient: string
        }
        Returns: Json
      }
      void_freelancer_payment: {
        Args: { p_payment: string; p_reason: string }
        Returns: Json
      }
      manage_profile_access: {
        Args: { p_new_active: boolean; p_new_role: string; p_reason: string; p_target: string }
        Returns: Json
      }
      pending_freelancer_registrations: {
        Args: never
        Returns: {
          email: string | null
          name: string
          profile_id: string
          requested_at: string
          whatsapp: string | null
        }[]
      }
      record_super_admin_user_action: {
        Args: { p_actor: string; p_event_type: string; p_reason: string; p_target: string }
        Returns: Json
      }
      record_managed_account_deletion: {
        Args: {
          p_actor: string
          p_reason: string
          p_target: string
          p_target_email: string
          p_target_label: string
        }
        Returns: Json
      }
      review_freelancer_registration: {
        Args: { p_actor: string; p_approve: boolean; p_reason: string; p_target: string }
        Returns: Json
      }
      set_created_account_role: {
        Args: { p_actor: string; p_new_role: string; p_reason: string; p_target: string }
        Returns: Json
      }
      set_freelancer_payment_schedule: {
        Args: { p_payout_frequency: string; p_profile: string }
        Returns: Json
      }
      super_admin_account_directory: {
        Args: never
        Returns: {
          email: string | null
          email_confirmed_at: string | null
          is_active: boolean
          last_seen: string
          name: string
          profile_id: string
          role: string
        }[]
      }
      super_admin_audit_log: {
        Args: never
        Returns: {
          actor_label: string
          actor_profile_id: string | null
          after_data: Json
          before_data: Json
          created_at: string
          event_type: string
          id: string
          reason: string
          target_label: string
          target_profile_id: string | null
        }[]
      }
      update_app_settings: {
        Args: { p_max_active_jobs: number | null; p_reason: string; p_sla_hours: number | null }
        Returns: Json
      }
      update_managed_account: {
        Args: {
          p_actor: string
          p_email_changed: boolean
          p_name: string
          p_old_email: string
          p_password_changed: boolean
          p_reason: string
          p_target: string
          p_whatsapp: string
        }
        Returns: Json
      }
      my_uid: { Args: never; Returns: string }
      promote_admin: {
        Args: { p_actor_label: string; p_reason: string; p_target: string }
        Returns: Json
      }
      promote_super_admin: {
        Args: { p_actor_label: string; p_reason: string; p_target: string }
        Returns: Json
      }
      release_upload_reservation: {
        Args: { p_reservation: string }
        Returns: Json
      }
      set_freelancer_availability: { Args: { p_status: string }; Returns: Json }
      set_freelancer_offline: { Args: never; Returns: Json }
      touch_freelancer_presence: { Args: never; Returns: Json }
      reserve_upload: { Args: { p_file_name: string; p_file_role: string; p_job: string; p_size: number }; Returns: Json }
      review_submission: {
        Args: {
          p_decision: string
          p_expected_rev: number
          p_review_note: string
          p_submission: string
        }
        Returns: Json
      }
      submit_preview: {
        Args: { p_expected_rev: number; p_file_ids: string[]; p_job: string; p_note: string }
        Returns: Json
      }
      finish_job: {
        Args: { p_expected_rev: number; p_job: string }
        Returns: Json
      }
      submit_for_acc: {
        Args: {
          p_expected_rev: number
          p_file_ids: string[]
          p_job: string
          p_note: string
        }
        Returns: Json
      }
      transition_job: {
        Args: {
          p_expected_rev: number
          p_job: string
          p_reason: string
          p_to: Database["public"]["Enums"]["job_status"]
        }
        Returns: Json
      }
      update_job_fields: {
        Args: {
          p_brief: string
          p_deadline: string
          p_expected_rev: number
          p_fee: number
          p_jenis: Database["public"]["Enums"]["job_type"]
          p_job: string
          p_priority: Database["public"]["Enums"]["job_priority"]
          p_qty: number
          p_ref: string
          p_tim: string
        }
        Returns: Json
      }
    }
    Enums: {
      job_priority: "normal" | "express"
      job_status:
        | "Belum Ditugaskan"
        | "Antre"
        | "Dikerjakan"
        | "Preview"
        | "MintaACC"
        | "Revisi"
        | "ACC"
        | "Finished"
        | "Dibatalkan"
      job_type:
        | "Fullprint"
        | "Printing Depan Saja"
        | "Jersey + Celana"
        | "Jaket"
      submission_decision: "pending" | "approved" | "revision_requested"
      upload_state: "active" | "committed" | "released" | "expired"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
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
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
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
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
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
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {
      job_priority: ["normal", "express"],
      job_status: [
        "Belum Ditugaskan",
        "Antre",
        "Dikerjakan",
        "Preview",
        "MintaACC",
        "Revisi",
        "ACC",
        "Finished",
        "Dibatalkan",
      ],
      job_type: [
        "Fullprint",
        "Printing Depan Saja",
        "Jersey + Celana",
        "Jaket",
      ],
      submission_decision: ["pending", "approved", "revision_requested"],
      upload_state: ["active", "committed", "released", "expired"],
    },
  },
} as const

