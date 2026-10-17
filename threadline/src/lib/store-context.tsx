"use client";

// Store data memakai API Threadline; otorisasi akhir tetap di PostgreSQL.

import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import { createClient, type ThreadlineClient } from "./backend/client";
import {
  hasOperationsAccess, validateFileKind, validateFreelancerBankAccount, type AccountDirectoryEntry, type AdminAuditEvent, type ChatMessage, type ChatThread,
  type FinanceMonthlyJob, type FinanceMonthlyPaymentRow, type FinancePaymentAuditRow, type FinancePaymentHistoryRow, type FinanceUnpaidJob, type FreelancerBankAccountDetails,
  type FreelancerBankAccount, type FreelancerPaymentSchedule, type FreelancerPaymentSetting, type FreelancerRegistrationRequest, type Job, type JobEvent, type JobFileMeta, type JobStatus, type Profile, type Role, type Submission,
} from "./domain";

type Sb = ThreadlineClient;

interface RpcOut { ok: boolean; error?: string; [k: string]: unknown }

interface RecordFreelancerPaymentInput {
  recipientProfileId: string;
  paidAt: string;
  bankReference: string;
  note: string;
  allocations: { jobId: string; amount: number }[];
  proof: File;
}

async function rpc(sb: Sb, fn: string, args: Record<string, unknown>): Promise<RpcOut> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) return { ok: false, error: error.message };
  return (data ?? { ok: false, error: "Respons kosong" }) as RpcOut;
}

// ---------- row -> domain ----------
function toProfile(r: Record<string, unknown>): Profile {
  const registrationStatus = r.registration_status;
  return {
    id: r.id as string,
    name: r.name as string,
    avatarPath: (r.avatar_path as string | null) ?? null,
    role: r.role as Profile["role"],
    isActive: r.is_active !== false,
    lastSeen: r.last_seen as string,
    availabilityStatus: r.availability_status === "ready" ? "ready" : r.availability_status === "unavailable" ? "unavailable" : "pending",
    availabilityUpdatedAt: (r.availability_updated_at as string | null) ?? null,
    registrationStatus: registrationStatus === "pending" || registrationStatus === "rejected" ? registrationStatus : "approved",
    registrationReviewReason: (r.registration_review_reason as string | null) ?? null,
  };
}
function toJob(r: Record<string, unknown>): Job {
  const g = (k: string) => r[k] as string | undefined;
  return {
    id: r.id as string, tim: r.tim as string, jenis: r.jenis as Job["jenis"],
    qty: r.qty as number, deadline: r.deadline as string, fee: Number(r.fee),
    approvedFee: r.approved_fee != null ? Number(r.approved_fee) : undefined,
    approvedForProfileId: (r.approved_for_profile_id as string) ?? undefined,
    assigneeId: (r.assignee_profile_id as string) ?? undefined,
    finishedAt: (r.finished_at as string | null) ?? undefined,
    status: r.status as Job["status"], priority: r.priority as Job["priority"],
    brief: (r.brief as string) ?? "-", ref: (r.ref as string) ?? undefined,
    currentSubmissionId: g("current_submission_id"), approvedSubmissionId: g("approved_submission_id"),
    createdAt: r.created_at as string, antreSince: g("antre_since"),
    cancelledAt: g("cancelled_at"), cancelledBy: g("cancelled_by_profile_id"),
    cancellationReason: g("cancellation_reason"), revision: r.revision as number,
  };
}
function toFile(r: Record<string, unknown>): JobFileMeta {
  return {
    id: r.id as string, jobId: r.job_id as string, name: r.name as string,
    path: r.path as string,
    fileKind: r.file_kind as JobFileMeta["fileKind"], sizeBytes: Number(r.size_bytes),
    fileRole: r.file_role === "reference" || r.file_role === "preview" || r.file_role === "source" ? r.file_role : "result",
    uploadedBy: (r.uploaded_by_profile_id as string) ?? "", uploadedAt: r.uploaded_at as string,
  };
}
function toSub(r: Record<string, unknown>, fileMap: Map<string, string[]>): Submission {
  return {
    id: r.id as string, jobId: r.job_id as string, version: r.version as number,
    submissionType: r.submission_kind === "preview" ? "preview" : "legacy",
    fileIds: fileMap.get(r.id as string) ?? [], note: (r.note as string) ?? undefined,
    decision: r.decision as Submission["decision"],
    reviewNote: (r.review_note as string) ?? undefined,
    submittedBy: (r.submitted_by_profile_id as string) ?? "",
    submittedAt: r.submitted_at as string,
    reviewedBy: (r.reviewed_by_profile_id as string) ?? undefined,
    reviewedAt: (r.reviewed_at as string) ?? undefined,
  };
}
function toEvent(r: Record<string, unknown>, nameOf: (id: string) => string): JobEvent {
  const actor = (r.actor_profile_id as string) ?? "";
  return {
    id: r.id as string, jobId: r.job_id as string, actorId: actor,
    actorName: actor ? nameOf(actor) : ((r.details as Record<string, string> | null)?.actor_label ?? "sistem"),
    type: r.event_type as string,
    fromStatus: (r.from_status as Job["status"]) ?? undefined,
    toStatus: (r.to_status as Job["status"]) ?? undefined,
    reason: (r.reason as string) ?? undefined,
    createdAt: r.created_at as string,
  };
}

export interface StoreData {
  profiles: Profile[];
  profilePhotoUrl: string | null;
  pendingFreelancerRegistrations: FreelancerRegistrationRequest[];
  freelancerBankAccount: FreelancerBankAccount | null;
  freelancerBankAccountError: string | null;
  accountDirectory: AccountDirectoryEntry[];
  adminAuditEvents: AdminAuditEvent[];
  profileNames: Record<string, string>;
  freelancerPaymentSettings: FreelancerPaymentSetting[];
  freelancerPaymentSettingsError: string | null;
  jobs: Job[];
  files: JobFileMeta[];
  submissions: Submission[];
  events: JobEvent[];
  threads: ChatThread[];
  messages: ChatMessage[];
  slaHours: number;
  maxActive: number;
}

interface Ctx {
  data: StoreData;
  currentProfile: Profile | null;
  authReady: boolean;
  userId: string | null;
  userEmail: string | null;
  realtime: "connecting" | "on" | "off";
  refresh: () => void;
  signOut: () => Promise<void>;
  renameProfile: (name: string) => Promise<{ ok: boolean; error?: string }>;
  saveProfilePhoto: (file: File) => Promise<{ ok: boolean; error?: string }>;
  beginFreelancerCheckIn: () => Promise<{ ok: boolean; error?: string }>;
  setFreelancerAvailability: (status: "ready" | "unavailable") => Promise<{ ok: boolean; error?: string }>;
  saveFreelancerBankAccount: (account: FreelancerBankAccount) => Promise<{ ok: boolean; error?: string }>;
  manageProfileAccess: (profileId: string, role: Role, isActive: boolean, reason: string) => Promise<{ ok: boolean; error?: string }>;
  setFreelancerPaymentSchedule: (profileId: string, schedule: FreelancerPaymentSchedule) => Promise<{ ok: boolean; error?: string }>;
  getFreelancerBankAccount: (profileId: string) => Promise<{ ok: boolean; error?: string; account?: FreelancerBankAccountDetails }>;
  financeMonthlyPaymentReport: (month: string) => Promise<{ ok: boolean; error?: string; rows: FinanceMonthlyPaymentRow[] }>;
  financeMonthlyJobs: (month: string, profileId: string, limit?: number, offset?: number) => Promise<{ ok: boolean; error?: string; rows: FinanceMonthlyJob[] }>;
  financeUnpaidJobs: (profileId: string, limit?: number, offset?: number) => Promise<{ ok: boolean; error?: string; rows: FinanceUnpaidJob[] }>;
  financePaymentHistory: (month: string, limit?: number, offset?: number) => Promise<{ ok: boolean; error?: string; rows: FinancePaymentHistoryRow[] }>;
  financePaymentAuditLog: (month: string, limit?: number, offset?: number) => Promise<{ ok: boolean; error?: string; rows: FinancePaymentAuditRow[] }>;
  recordFreelancerPayment: (input: RecordFreelancerPaymentInput) => Promise<{ ok: boolean; error?: string; paymentId?: string }>;
  voidFreelancerPayment: (paymentId: string, reason: string) => Promise<{ ok: boolean; error?: string }>;
  openFinancePaymentProof: (paymentId: string) => Promise<{ ok: boolean; error?: string; url?: string }>;
  reviewFreelancerRegistration: (profileId: string, decision: "approve" | "reject", reason: string) => Promise<{ ok: boolean; error?: string }>;
  createJob: (input: Partial<Job>) => Promise<{ ok: boolean; error?: string; id?: string }>;
  assignJob: (jobId: string, targetId: string, reason?: string) => Promise<{ ok: boolean; error?: string }>;
  transition: (jobId: string, to: JobStatus, opts?: { reason?: string; submissionId?: string }) => Promise<{ ok: boolean; error?: string }>;
  uploadFile: (jobId: string, file: File, fileRole: Exclude<JobFileMeta["fileRole"], "result">) => Promise<{ ok: boolean; error?: string }>;
  deleteFile: (fileId: string) => Promise<{ ok: boolean; error?: string }>;
  fileUrl: (path: string) => Promise<string | null>;
  submitPreview: (jobId: string, fileIds: string[], note?: string) => Promise<{ ok: boolean; error?: string }>;
  finishJob: (jobId: string) => Promise<{ ok: boolean; error?: string }>;
  sendMessage: (threadId: string, text: string) => Promise<{ ok: boolean; error?: string }>;
  updateSla: (hours: number, reason: string) => Promise<{ ok: boolean; error?: string }>;
  updateCapacity: (limit: number, reason: string) => Promise<{ ok: boolean; error?: string }>;
  cancelJob: (jobId: string, reason: string) => Promise<{ ok: boolean; error?: string }>;
  deleteJobPermanent: (jobId: string) => Promise<{ ok: boolean; error?: string }>;
  updateJobFields: (jobId: string, patch: Partial<Job>) => Promise<{ ok: boolean; error?: string }>;
}

const StoreCtx = createContext<Ctx | null>(null);
const EMPTY: StoreData = { profiles: [], profilePhotoUrl: null, pendingFreelancerRegistrations: [], freelancerBankAccount: null, freelancerBankAccountError: null, accountDirectory: [], adminAuditEvents: [], profileNames: {}, freelancerPaymentSettings: [], freelancerPaymentSettingsError: null, jobs: [], files: [], submissions: [], events: [], threads: [], messages: [], slaHours: 3, maxActive: 4 };

export function StoreProvider({ children }: { children: React.ReactNode }) {
  const [sb] = useState<Sb>(() => createClient());
  const [data, setData] = useState<StoreData>(EMPTY);
  const [userId, setUserId] = useState<string | null>(null);
  const [userEmail, setUserEmail] = useState<string | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [realtime, setRealtime] = useState<"connecting" | "on" | "off">("connecting");
  const debounce = useRef<ReturnType<typeof setTimeout> | null>(null);

  const currentProfile = useMemo(
    () => data.profiles.find((p) => p.id === userId) ?? null,
    [data.profiles, userId],
  );

  const load = useCallback(async () => {
    const { data: { user } } = await sb.auth.getUser();
    if (!user) {
      if (typeof window !== "undefined") {
        Object.keys(window.sessionStorage)
          .filter((key) => key.startsWith("threadline:freelancer-checkin:"))
          .forEach((key) => window.sessionStorage.removeItem(key));
      }
      setUserId(null); setUserEmail(null); setData(EMPTY); setAuthReady(true);
      return;
    }
    setUserId(user.id);
    setUserEmail(user.email ?? null);
    const roleResult = await sb.from("profiles").select("role").eq("id", user.id).maybeSingle();
    const financeReadOnly = roleResult.data?.role === "finance";
    const emptyResult = { data: [], error: null };
    const emptySingleResult = { data: null, error: null };
    const [profileResult, contactResult, jobs, files, subs, links, events, threads, msgs, settings] = await Promise.all([
      sb.from("profiles").select("id,name,avatar_path,role,is_active,last_seen,registration_status,registration_review_reason,availability_status,availability_updated_at"),
      financeReadOnly ? Promise.resolve(emptyResult) : sb.from("profile_contacts").select("profile_id,whatsapp"),
      financeReadOnly ? Promise.resolve(emptyResult) : sb.from("jobs").select("*").order("created_at", { ascending: false }).limit(500),
      financeReadOnly ? Promise.resolve(emptyResult) : sb.from("job_files").select("*").order("uploaded_at", { ascending: false }).limit(2000),
      financeReadOnly ? Promise.resolve(emptyResult) : sb.from("job_submissions").select("*").order("submitted_at", { ascending: false }).limit(1000),
      financeReadOnly ? Promise.resolve(emptyResult) : sb.from("job_submission_files").select("submission_id,job_file_id").limit(5000),
      financeReadOnly ? Promise.resolve(emptyResult) : sb.from("job_events").select("*").order("created_at", { ascending: true }).limit(3000),
      financeReadOnly ? Promise.resolve(emptyResult) : sb.from("chat_threads").select("*"),
      financeReadOnly ? Promise.resolve(emptyResult) : sb.from("chat_messages").select("*").order("created_at", { ascending: true }).limit(2000),
      financeReadOnly ? Promise.resolve(emptySingleResult) : sb.from("app_settings").select("urgency_sla_hours,max_active_jobs").eq("id", 1).maybeSingle(),
    ]);
    let profileRows = (profileResult.data ?? []) as Record<string, unknown>[];
    const profileError = profileResult.error;
    const contactByProfile = new Map(
      ((contactResult.data ?? []) as { profile_id: string; whatsapp: string }[])
        .map((contact) => [contact.profile_id, contact.whatsapp]),
    );
    if (profileError && /(avatar_path|is_active|registration_|availability_)/i.test(profileError.message)) {
      const legacyProfiles = await sb.from("profiles").select("id,name,role,last_seen");
      profileRows = (legacyProfiles.data ?? []) as unknown as Record<string, unknown>[];
    }
    const profiles = profileRows.map((row) => ({
      ...toProfile(row),
      whatsapp: contactByProfile.get(row.id as string) ?? null,
    }));
    const profileNames = Object.fromEntries(profiles.map((profile) => [profile.id, profile.name]));
    let pendingFreelancerRegistrations: FreelancerRegistrationRequest[] = [];
    const signedInProfile = profiles.find((profile) => profile.id === user.id);
    let profilePhotoUrl: string | null = null;
    if (signedInProfile?.avatarPath) {
      const { data: signedPhoto, error: signedPhotoError } = await sb.storage
        .from("profile-photos")
        .createSignedUrl(signedInProfile.avatarPath, 604800);
      if (!signedPhotoError) profilePhotoUrl = signedPhoto?.signedUrl ?? null;
    }
    let freelancerBankAccount: FreelancerBankAccount | null = null;
    let freelancerBankAccountError: string | null = null;
    if (signedInProfile?.role === "freelance") {
      const bankResult = await sb.from("freelancer_bank_accounts")
        .select("bank_name,account_number,account_holder")
        .eq("profile_id", user.id)
        .maybeSingle();
      if (bankResult.error) {
        freelancerBankAccountError = bankResult.error.message;
      } else if (bankResult.data) {
        freelancerBankAccount = {
          bankName: bankResult.data.bank_name,
          accountNumber: bankResult.data.account_number,
          accountHolder: bankResult.data.account_holder,
        };
      }
    }
    if (signedInProfile && hasOperationsAccess(signedInProfile.role)) {
      const registrationsResult = await sb.rpc("pending_freelancer_registrations");
      if (!registrationsResult.error) {
        pendingFreelancerRegistrations = ((registrationsResult.data ?? []) as {
          profile_id: string; name: string; email: string | null; whatsapp: string | null; requested_at: string;
        }[]).map((registration) => ({
          profileId: registration.profile_id,
          name: registration.name,
          email: registration.email ?? "",
          whatsapp: registration.whatsapp,
          requestedAt: registration.requested_at,
        }));
      }
    }
    let accountDirectory: AccountDirectoryEntry[] = [];
    let adminAuditEvents: AdminAuditEvent[] = [];
    const signedInRole = profiles.find((profile) => profile.id === user.id)?.role;
    if (signedInRole === "super_admin") {
      const accountsResult = await sb.rpc("managed_account_directory");
      if (!accountsResult.error) {
        accountDirectory = ((accountsResult.data ?? []) as { profile_id: string; email: string | null; email_confirmed_at: string | null }[])
          .map((account) => ({ profileId: account.profile_id, email: account.email ?? "", emailConfirmedAt: account.email_confirmed_at }));
      }
      const auditResult = await sb.rpc("super_admin_audit_log");
      if (!auditResult.error) {
        adminAuditEvents = ((auditResult.data ?? []) as {
          id: string; event_type: string; target_profile_id: string | null; target_label: string;
          actor_profile_id: string | null; actor_label: string; before_data: Record<string, unknown>;
          after_data: Record<string, unknown>; reason: string; created_at: string;
        }[]).map((event) => ({
          id: event.id, eventType: event.event_type, targetProfileId: event.target_profile_id,
          targetLabel: event.target_label, actorProfileId: event.actor_profile_id,
          actorLabel: event.actor_label, beforeData: event.before_data ?? {}, afterData: event.after_data ?? {},
          reason: event.reason, createdAt: event.created_at,
        }));
      }
    }
    let freelancerPaymentSettings: FreelancerPaymentSetting[] = [];
    let freelancerPaymentSettingsError: string | null = null;
    if (profiles.find((profile) => profile.id === user.id)?.role === "finance") {
      const paymentSettingsResult = await sb.rpc("finance_freelancer_payment_settings");
      if (paymentSettingsResult.error) {
        freelancerPaymentSettingsError = paymentSettingsResult.error.message;
      } else {
        freelancerPaymentSettings = ((paymentSettingsResult.data ?? []) as {
          profile_id: string;
          profile_name: string;
          is_active: boolean;
          payout_frequency: FreelancerPaymentSchedule;
          payout_method: "bank_transfer";
          bank_name: string | null;
          account_number: string | null;
          account_holder: string | null;
          updated_at: string | null;
        }[]).map((row) => ({
          profileId: row.profile_id,
          profileName: row.profile_name,
          isActive: row.is_active,
          schedule: row.payout_frequency,
          paymentMethod: row.payout_method,
          bankName: row.bank_name,
          accountNumber: row.account_number,
          accountHolder: row.account_holder,
          updatedAt: row.updated_at,
        }));
      }
    }
    const nameOf = (id: string) => profileNames[id] ?? id;
    const fileMap = new Map<string, string[]>();
    for (const l of ((links.data ?? []) as { submission_id: string; job_file_id: string }[])) {
      const arr = fileMap.get(l.submission_id) ?? [];
      arr.push(l.job_file_id);
      fileMap.set(l.submission_id, arr);
    }
    // file terkunci bila terikat submission mana pun
    const locked = new Set<string>();
    for (const ids of fileMap.values()) ids.forEach((id) => locked.add(id));
    setData({
      profiles,
      profilePhotoUrl,
      pendingFreelancerRegistrations,
      freelancerBankAccount,
      freelancerBankAccountError,
      accountDirectory,
      adminAuditEvents,
      profileNames,
      freelancerPaymentSettings,
      freelancerPaymentSettingsError,
      jobs: ((jobs.data ?? []) as Record<string, unknown>[]).map(toJob),
      files: ((files.data ?? []) as Record<string, unknown>[]).map((r) => ({
        ...toFile(r),
        lockedSubmissionId: locked.has(r.id as string) ? "bound" : undefined,
      })),
      submissions: ((subs.data ?? []) as Record<string, unknown>[]).map((r) => toSub(r, fileMap)),
      events: ((events.data ?? []) as Record<string, unknown>[]).map((r) => toEvent(r, nameOf)),
      threads: ((threads.data ?? []) as { id: string; freelance_profile_id: string; created_at: string }[])
        .map((t) => ({ id: t.id, freelanceId: t.freelance_profile_id, createdAt: t.created_at })),
      messages: ((msgs.data ?? []) as { id: string; thread_id: string; sender_profile_id: string; text: string; created_at: string }[])
        .map((m) => ({ id: m.id, threadId: m.thread_id, senderId: m.sender_profile_id, senderName: nameOf(m.sender_profile_id), text: m.text, createdAt: m.created_at })),
      slaHours: Number((settings.data as { urgency_sla_hours: number } | null)?.urgency_sla_hours ?? 3),
      maxActive: Number((settings.data as { max_active_jobs: number } | null)?.max_active_jobs ?? 4),
    });
    setAuthReady(true);
  }, [sb]);

  const refresh = useCallback(() => { void load(); }, [load]);

  // Heartbeat server-side tiap 30 detik; klien tidak boleh menentukan last_seen.
  useEffect(() => {
    if (!userId || currentProfile?.role !== "freelance" || !currentProfile.isActive || currentProfile.registrationStatus !== "approved") return;
    const beat = () => {
      void rpc(sb, "touch_freelancer_presence", {});
    };
    beat();
    const t = setInterval(beat, 30_000);
    return () => clearInterval(t);
  }, [sb, userId, currentProfile?.id, currentProfile?.role, currentProfile?.isActive, currentProfile?.registrationStatus]);

  // Muat awal + saat sesi auth berubah.
  useEffect(() => {
    const t = setTimeout(() => { void load(); }, 0);
    const { data: sub } = sb.auth.onAuthStateChange(() => { void load(); });
    return () => { clearTimeout(t); sub.subscription.unsubscribe(); };
  }, [sb, load]);

  // Realtime jobs + chat (debounce 800 ms, sesuai kontrak §4).
  useEffect(() => {
    if (!userId) {
      const t = setTimeout(() => setRealtime("off"), 0);
      return () => clearTimeout(t);
    }
    if (currentProfile?.role === "finance") {
      const t = setTimeout(() => setRealtime("off"), 0);
      return () => clearTimeout(t);
    }
    let cancelled = false;
    const t = setTimeout(() => { if (!cancelled) setRealtime("connecting"); }, 0);
    const schedule = () => {
      if (debounce.current) clearTimeout(debounce.current);
      debounce.current = setTimeout(() => { void load(); }, 800);
    };
    const ch = sb.channel("threadline")
      .on("postgres_changes", { event: "*", schema: "public", table: "jobs" }, schedule)
      .on("postgres_changes", { event: "*", schema: "public", table: "job_files" }, schedule)
      .on("postgres_changes", { event: "*", schema: "public", table: "job_submissions" }, schedule)
      .on("postgres_changes", { event: "*", schema: "public", table: "job_events" }, schedule)
      .on("postgres_changes", { event: "*", schema: "public", table: "chat_threads" }, schedule)
      .on("postgres_changes", { event: "*", schema: "public", table: "chat_messages" }, schedule)
      .on("postgres_changes", { event: "*", schema: "public", table: "app_settings" }, schedule)
      .on("postgres_changes", { event: "*", schema: "public", table: "profiles" }, schedule)
      .subscribe((status) => {
        if (status === "SUBSCRIBED") setRealtime("on");
        else if (status === "CLOSED" || status === "CHANNEL_ERROR" || status === "TIMED_OUT") setRealtime("off");
      });
    return () => { cancelled = true; clearTimeout(t); void sb.removeChannel(ch); };
  }, [sb, userId, currentProfile?.role, load]);

  const value: Ctx = useMemo(() => {
    const revOf = (jobId: string) => data.jobs.find((j) => j.id === jobId)?.revision ?? 0;
    return {
      data, currentProfile, authReady, userId, userEmail, realtime, refresh,
      signOut: async () => {
        if (currentProfile?.role === "freelance" && userId) {
          try {
            await rpc(sb, "set_freelancer_offline", {});
          } catch {
            // Sign-out should still work when presence cannot be updated.
          }
          if (typeof window !== "undefined") window.sessionStorage.removeItem(`threadline:freelancer-checkin:${userId}`);
        }
        await sb.auth.signOut();
      },
      renameProfile: async (name) => {
        if (!userId) return { ok: false, error: "Belum masuk" };
        const n = name.trim();
        if (!n) return { ok: false, error: "Nama tidak boleh kosong" };
        const { error } = await sb.from("profiles").update({ name: n }).eq("id", userId);
        if (error) return { ok: false, error: /duplicate|unique/i.test(error.message) ? "Nama profil harus unik" : error.message };
        await load();
        return { ok: true };
      },
      saveProfilePhoto: async (file) => {
        if (!userId || currentProfile?.role !== "freelance" || !currentProfile.isActive || currentProfile.registrationStatus !== "approved") {
          return { ok: false, error: "Hanya freelancer yang sudah disetujui yang dapat mengganti foto profil." };
        }
        const extensionByType: Record<string, string> = {
          "image/jpeg": "jpg",
          "image/png": "png",
          "image/webp": "webp",
        };
        const extension = extensionByType[file.type];
        if (!extension) return { ok: false, error: "Gunakan foto JPG, PNG, atau WebP." };
        if (file.size <= 0 || file.size > 5 * 1024 * 1024) return { ok: false, error: "Ukuran foto maksimal 5 MB." };

        const path = `${userId}/avatar-${Date.now()}.${extension}`;
        const { error: uploadError } = await sb.storage.from("profile-photos").upload(path, file, {
          contentType: file.type,
          cacheControl: "3600",
          upsert: false,
        });
        if (uploadError) return { ok: false, error: uploadError.message };

        const previousPath = currentProfile.avatarPath;
        const { error: profileError } = await sb.from("profiles").update({ avatar_path: path }).eq("id", userId);
        if (profileError) {
          await sb.storage.from("profile-photos").remove([path]);
          return { ok: false, error: profileError.message };
        }
        if (previousPath && previousPath !== path) {
          await sb.storage.from("profile-photos").remove([previousPath]);
        }
        await load();
        return { ok: true };
      },
      beginFreelancerCheckIn: async () => {
        if (!userId || currentProfile?.role !== "freelance" || !currentProfile.isActive || currentProfile.registrationStatus !== "approved") {
          return { ok: false, error: "Hanya freelancer yang sudah disetujui yang dapat check-in." };
        }
        const result = await rpc(sb, "set_freelancer_availability", { p_status: "pending" });
        if (!result.ok) return result;
        await load();
        return { ok: true };
      },
      setFreelancerAvailability: async (status) => {
        if (!userId || currentProfile?.role !== "freelance" || !currentProfile.isActive || currentProfile.registrationStatus !== "approved") {
          return { ok: false, error: "Hanya freelancer yang sudah disetujui yang dapat mengubah kesiapan." };
        }
        const result = await rpc(sb, "set_freelancer_availability", { p_status: status });
        if (!result.ok) return result;
        await load();
        return { ok: true };
      },
      saveFreelancerBankAccount: async (account) => {
        if (!userId || currentProfile?.role !== "freelance") return { ok: false, error: "Hanya freelancer aktif yang dapat menyimpan rekening." };
        const validationError = validateFreelancerBankAccount(account);
        if (validationError) return { ok: false, error: validationError };
        const { error } = await sb.from("freelancer_bank_accounts").upsert({
          profile_id: userId,
          bank_name: account.bankName.trim(),
          account_number: account.accountNumber.trim(),
          account_holder: account.accountHolder.trim(),
          updated_at: new Date().toISOString(),
        }, { onConflict: "profile_id" });
        if (error) return { ok: false, error: error.message };
        await load();
        return { ok: true };
      },
      manageProfileAccess: async (profileId, role, isActive, reason) => {
        const trimmedReason = reason.trim();
        if (!trimmedReason) return { ok: false, error: "Alasan perubahan wajib diisi" };
        const r = await rpc(sb, "manage_profile_access", {
          p_target: profileId,
          p_new_role: role,
          p_new_active: isActive,
          p_reason: trimmedReason,
        });
        if (!r.ok) return r;
        await load();
        return { ok: true };
      },
      setFreelancerPaymentSchedule: async (profileId, schedule) => {
        if (currentProfile?.role !== "finance") return { ok: false, error: "Hanya Finance yang dapat mengatur jadwal pembayaran." };
        const r = await rpc(sb, "set_freelancer_payment_schedule", {
          p_profile: profileId,
          p_payout_frequency: schedule,
        });
        if (!r.ok) return r;
        await load();
        return { ok: true };
      },
      getFreelancerBankAccount: async (profileId) => {
        const result = await sb.rpc("finance_freelancer_bank_account", { p_profile: profileId });
        if (result.error) return { ok: false, error: result.error.message };
        const row = ((result.data ?? []) as { bank_name: string; account_number: string; account_holder: string }[])[0];
        if (!row) return { ok: false, error: "Rekening freelancer belum tersedia." };
        return { ok: true, account: { bankName: row.bank_name, accountNumber: row.account_number, accountHolder: row.account_holder } };
      },
      financeMonthlyPaymentReport: async (month) => {
        const result = await sb.rpc("finance_monthly_payment_report", { p_month: `${month}-01` });
        if (result.error) return { ok: false, error: result.error.message, rows: [] };
        const rows = ((result.data ?? []) as {
          profile_id: string; profile_name: string; opening_balance: number; earned_this_month: number;
          paid_this_month: number; closing_balance: number; jobs_finished_this_month: number;
        }[]).map((row) => ({
          profileId: row.profile_id, profileName: row.profile_name,
          openingBalance: Number(row.opening_balance), earnedThisMonth: Number(row.earned_this_month),
          paidThisMonth: Number(row.paid_this_month), closingBalance: Number(row.closing_balance),
          jobsFinishedThisMonth: Number(row.jobs_finished_this_month),
        }));
        return { ok: true, rows };
      },
      financeMonthlyJobs: async (month, profileId, limit = 50, offset = 0) => {
        const result = await sb.rpc("finance_monthly_jobs", { p_month: `${month}-01`, p_profile: profileId, p_limit: limit, p_offset: offset });
        if (result.error) return { ok: false, error: result.error.message, rows: [] };
        const rows = ((result.data ?? []) as {
          job_id: string; team_name: string; job_type: Job["jenis"]; finished_at: string;
          earned_fee: number; paid_amount: number; due_amount: number; total_rows: number;
        }[]).map((row) => ({
          jobId: row.job_id, teamName: row.team_name, jobType: row.job_type, finishedAt: row.finished_at,
          earnedFee: Number(row.earned_fee), paidAmount: Number(row.paid_amount), dueAmount: Number(row.due_amount),
          totalRows: Number(row.total_rows),
        }));
        return { ok: true, rows };
      },
      financeUnpaidJobs: async (profileId, limit = 50, offset = 0) => {
        const result = await sb.rpc("finance_unpaid_jobs", { p_profile: profileId, p_limit: limit, p_offset: offset });
        if (result.error) return { ok: false, error: result.error.message, rows: [] };
        const rows = ((result.data ?? []) as {
          job_id: string; team_name: string; job_type: Job["jenis"]; finished_at: string;
          earned_fee: number; paid_amount: number; due_amount: number; total_rows: number;
        }[]).map((row) => ({
          jobId: row.job_id, teamName: row.team_name, jobType: row.job_type, finishedAt: row.finished_at,
          earnedFee: Number(row.earned_fee), paidAmount: Number(row.paid_amount), dueAmount: Number(row.due_amount),
          totalRows: Number(row.total_rows),
        }));
        return { ok: true, rows };
      },
      financePaymentHistory: async (month, limit = 50, offset = 0) => {
        const result = await sb.rpc("finance_payment_history", { p_month: `${month}-01`, p_limit: limit, p_offset: offset });
        if (result.error) return { ok: false, error: result.error.message, rows: [] };
        const rows = ((result.data ?? []) as {
          payment_id: string; recipient_profile_id: string; recipient_name: string; bank_name: string | null;
          account_number_last4: string | null; account_holder: string | null; amount: number;
          paid_at: string; bank_reference: string; note: string; proof_path: string; status: "posted" | "voided";
          recorded_by: string; recorded_at: string; voided_by: string | null; voided_at: string | null;
          void_reason: string | null; allocations: { job_id: string; team_name: string; amount: number }[]; total_rows: number;
        }[]).map((row) => ({
          paymentId: row.payment_id, recipientProfileId: row.recipient_profile_id, recipientName: row.recipient_name,
          bankName: row.bank_name, accountNumberLast4: row.account_number_last4, accountHolder: row.account_holder,
          amount: Number(row.amount), paidAt: row.paid_at, bankReference: row.bank_reference, note: row.note,
          proofPath: row.proof_path, status: row.status, recordedBy: row.recorded_by, recordedAt: row.recorded_at,
          voidedBy: row.voided_by, voidedAt: row.voided_at, voidReason: row.void_reason,
          allocations: (row.allocations ?? []).map((allocation) => ({
            jobId: allocation.job_id, teamName: allocation.team_name, amount: Number(allocation.amount),
          })),
          totalRows: Number(row.total_rows),
        }));
        return { ok: true, rows };
      },
      financePaymentAuditLog: async (month, limit = 100, offset = 0) => {
        const result = await sb.rpc("finance_payment_audit_log", { p_month: `${month}-01`, p_limit: limit, p_offset: offset });
        if (result.error) return { ok: false, error: result.error.message, rows: [] };
        const rows = ((result.data ?? []) as {
          event_id: string; payment_record_id: string | null; target_profile_id: string | null; target_name: string;
          actor_name: string; event_type: FinancePaymentAuditRow["eventType"]; details: Record<string, unknown>;
          created_at: string; total_rows: number;
        }[]).map((row) => ({
          eventId: row.event_id, paymentRecordId: row.payment_record_id, targetProfileId: row.target_profile_id,
          targetName: row.target_name, actorName: row.actor_name, eventType: row.event_type,
          details: row.details ?? {}, createdAt: row.created_at, totalRows: Number(row.total_rows),
        }));
        return { ok: true, rows };
      },
      recordFreelancerPayment: async (input) => {
        if (!userId || (currentProfile?.role !== "finance" && currentProfile?.role !== "super_admin")) {
          return { ok: false, error: "Hanya Finance yang dapat mencatat pembayaran." };
        }
        const extension = input.proof.name.split(".").pop()?.toLowerCase();
        const allowedTypes = ["application/pdf", "image/jpeg", "image/png", "image/webp"];
        if (!input.proof.size || input.proof.size > 10 * 1024 * 1024 || !allowedTypes.includes(input.proof.type) || !["pdf", "jpg", "jpeg", "png", "webp"].includes(extension ?? "")) {
          return { ok: false, error: "Bukti harus berupa PDF, JPG, PNG, atau WebP dengan ukuran maksimal 10 MB." };
        }
        const safeName = input.proof.name.replace(/[^a-zA-Z0-9._-]+/g, "_");
        const path = `${userId}/${Date.now()}-${globalThis.crypto.randomUUID()}-${safeName}`;
        const uploaded = await sb.storage.from("finance-payment-proofs").upload(path, input.proof, {
          contentType: input.proof.type, upsert: false,
        });
        if (uploaded.error) return { ok: false, error: uploaded.error.message };
        const result = await rpc(sb, "record_freelancer_payment", {
          p_recipient: input.recipientProfileId,
          p_paid_at: input.paidAt,
          p_bank_reference: input.bankReference.trim(),
          p_note: input.note.trim(),
          p_proof_path: path,
          p_allocations: input.allocations.map((allocation) => ({ job_id: allocation.jobId, amount: allocation.amount })),
        });
        if (!result.ok) {
          await sb.storage.from("finance-payment-proofs").remove([path]);
          return result;
        }
        await load();
        return { ok: true, paymentId: result.payment_id as string };
      },
      voidFreelancerPayment: async (paymentId, reason) => {
        const result = await rpc(sb, "void_freelancer_payment", { p_payment: paymentId, p_reason: reason.trim() });
        if (!result.ok) return result;
        await load();
        return { ok: true };
      },
      openFinancePaymentProof: async (paymentId) => {
        const result = await rpc(sb, "finance_log_payment_proof_view", { p_payment: paymentId });
        if (!result.ok || typeof result.proof_path !== "string") return { ok: false, error: result.error ?? "Bukti pembayaran tidak tersedia." };
        const signed = await sb.storage.from("finance-payment-proofs").createSignedUrl(result.proof_path, 300);
        if (signed.error || !signed.data) return { ok: false, error: signed.error?.message ?? "Bukti pembayaran gagal dibuka." };
        return { ok: true, url: signed.data.signedUrl };
      },
      reviewFreelancerRegistration: async (profileId, decision, reason) => {
        try {
          const response = await fetch(`/api/backend/freelancer-registrations/${profileId}/review`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ decision, reason }),
          });
          const result = await response.json() as { error?: string };
          if (!response.ok) return { ok: false, error: result.error ?? "Keputusan pendaftaran gagal disimpan." };
          await load();
          return { ok: true };
        } catch {
          return { ok: false, error: "Tidak dapat terhubung untuk memproses pendaftaran." };
        }
      },
      createJob: async (input) => {
        const r = await rpc(sb, "create_job", {
          p_tim: (input.tim ?? "").trim() || "Tanpa Nama Tim",
          p_jenis: input.jenis ?? "Fullprint",
          p_qty: input.qty ?? 1,
          p_deadline: input.deadline ?? new Date(Date.now() + 3 * 86400_000).toISOString(),
          p_fee: input.fee ?? 0,
          p_priority: input.priority ?? "normal",
          p_brief: (input.brief ?? "").trim() || "-",
          p_ref: input.ref ?? null,
        });
        if (!r.ok) return r;
        await load();
        return { ok: true, id: r.id as string };
      },
      assignJob: async (jobId, targetId, reason) => {
        const r = await rpc(sb, "assign_job", { p_job: jobId, p_target: targetId, p_reason: reason ?? null, p_expected_rev: revOf(jobId) });
        if (!r.ok) return r;
        await load();
        return { ok: true };
      },
      transition: async (jobId, to, opts) => {
        let r: RpcOut;
        if (to === "ACC") {
          if (!opts?.submissionId) return { ok: false, error: "Submission tidak dipilih" };
          r = await rpc(sb, "review_submission", { p_submission: opts.submissionId, p_decision: "approved", p_review_note: null, p_expected_rev: revOf(jobId) });
        } else if (to === "Revisi") {
          if (!opts?.submissionId) return { ok: false, error: "Submission tidak dipilih" };
          r = await rpc(sb, "review_submission", { p_submission: opts.submissionId, p_decision: "revision", p_review_note: opts.reason ?? null, p_expected_rev: revOf(jobId) });
        } else {
          r = await rpc(sb, "transition_job", { p_job: jobId, p_to: to, p_reason: opts?.reason ?? null, p_expected_rev: revOf(jobId) });
        }
        if (!r.ok) return r;
        await load();
        return { ok: true };
      },
      uploadFile: async (jobId, file, fileRole) => {
        const kind = validateFileKind(file.name);
        if (!kind) return { ok: false, error: "Format file tidak didukung" };
        if (file.size > 1073741824) return { ok: false, error: "Maks 1 GiB per file" };
        const res = await rpc(sb, "reserve_upload", {
          p_job: jobId,
          p_size: file.size,
          p_file_name: file.name,
          p_file_role: fileRole,
        });
        if (!res.ok || !res.reservation_id || !res.object_path) return res.ok
          ? { ok: false, error: "Server tidak mengembalikan jalur unggahan." }
          : res;
        const rid = res.reservation_id as string;
        const path = res.object_path as string;
        const fail = async (msg: string) => {
          await rpc(sb, "release_upload_reservation", { p_reservation: rid });
          return { ok: false, error: msg };
        };
        const up = await sb.storage.from("job-files").upload(path, file, { contentType: file.type || undefined, upsert: false });
        if (up.error) return fail(up.error.message);
        const ins = await sb.from("job_files").insert({
          job_id: jobId, name: file.name, path, file_kind: kind, file_role: fileRole,
          size_bytes: file.size, reservation_id: rid,
        });
        if (ins.error) {
          await sb.storage.from("job-files").remove([path]);
          return fail(ins.error.message);
        }
        await load();
        return { ok: true };
      },
      deleteFile: async (fileId) => {
        const { error } = await sb.from("job_files").delete().eq("id", fileId);
        if (error) return { ok: false, error: /FILE_LOCKED/i.test(error.message) ? "File terikat submission, terkunci" : error.message };
        await load();
        return { ok: true };
      },
      fileUrl: async (path) => {
        const { data: s, error } = await sb.storage.from("job-files").createSignedUrl(path, 300);
        if (error || !s) return null;
        return s.signedUrl;
      },
      submitPreview: async (jobId, fileIds, note) => {
        const r = await rpc(sb, "submit_preview", { p_job: jobId, p_file_ids: fileIds, p_note: note ?? null, p_expected_rev: revOf(jobId) });
        if (!r.ok) return r;
        await load();
        return { ok: true };
      },
      finishJob: async (jobId) => {
        const r = await rpc(sb, "finish_job", { p_job: jobId, p_expected_rev: revOf(jobId) });
        if (!r.ok) return r;
        await load();
        return { ok: true };
      },
      sendMessage: async (threadId, text) => {
        if (!userId) return { ok: false, error: "Belum masuk" };
        const t = text.trim();
        if (!t) return { ok: false, error: "Pesan kosong" };
        if (t.length > 500) return { ok: false, error: "Maks 500 karakter" };
        const { error } = await sb.from("chat_messages").insert({ thread_id: threadId, sender_profile_id: userId, text: t.slice(0, 500) });
        if (error) return { ok: false, error: error.message };
        await load();
        return { ok: true };
      },
      updateSla: async (hours, reason) => {
        if (!(hours > 0 && hours <= 72)) return { ok: false, error: "SLA 1-72 jam" };
        const r = await rpc(sb, "update_app_settings", { p_sla_hours: hours, p_max_active_jobs: null, p_reason: reason.trim() });
        if (!r.ok) return r;
        await load();
        return { ok: true };
      },
      updateCapacity: async (limit, reason) => {
        if (!(Number.isInteger(limit) && limit >= 1 && limit <= 20)) return { ok: false, error: "Batas 1-20 job" };
        const r = await rpc(sb, "update_app_settings", { p_sla_hours: null, p_max_active_jobs: limit, p_reason: reason.trim() });
        if (!r.ok) return r;
        await load();
        return { ok: true };
      },
      cancelJob: async (jobId, reason) => {
        const r = await rpc(sb, "cancel_job", { p_job: jobId, p_reason: reason, p_expected_rev: revOf(jobId) });
        if (!r.ok) return r;
        await load();
        return { ok: true };
      },
      deleteJobPermanent: async (jobId) => {
        const r = await rpc(sb, "delete_job", { p_job: jobId });
        if (!r.ok) return r;
        await load();
        return { ok: true };
      },
      updateJobFields: async (jobId, patch) => {
        const r = await rpc(sb, "update_job_fields", {
          p_job: jobId, p_expected_rev: revOf(jobId),
          p_tim: patch.tim ?? null, p_jenis: patch.jenis ?? null, p_qty: patch.qty ?? null,
          p_deadline: patch.deadline ?? null, p_fee: patch.fee ?? null,
          p_priority: patch.priority ?? null, p_brief: patch.brief ?? null, p_ref: patch.ref ?? null,
        });
        if (!r.ok) return r;
        await load();
        return { ok: true };
      },
    };
  }, [sb, data, currentProfile, authReady, userId, userEmail, realtime, refresh, load]);

  return <StoreCtx.Provider value={value}>{children}</StoreCtx.Provider>;
}

export function useStore(): Ctx {
  const ctx = useContext(StoreCtx);
  if (!ctx) throw new Error("useStore harus di dalam StoreProvider");
  return ctx;
}

// Dipakai layar dalam yang mensyaratkan profil sudah ada.
export function useReadyStore(): Ctx & { currentProfile: Profile } {
  const ctx = useStore();
  if (!ctx.currentProfile) throw new Error("Profil belum siap");
  return ctx as Ctx & { currentProfile: Profile };
}
