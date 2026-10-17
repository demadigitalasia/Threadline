// Domain Threadline — kontrak perilaku UI/Demo, diturunkan dari PRD §4 dan TECHNICAL-CONTRACT.
// Backend Mode Online akan menegakkan ulang aturan ini secara atomik; validasi di sini hanya untuk Demo.

export type Role = "super_admin" | "finance" | "admin" | "freelance";
export const ROLE_ORDER: Role[] = ["super_admin", "finance", "admin", "freelance"];
export const ROLE_LABELS: Record<Role, string> = {
  super_admin: "Super Admin",
  finance: "Finance",
  admin: "Admin",
  freelance: "Freelance",
};

export function hasOperationsAccess(role: Role): boolean {
  return role === "super_admin" || role === "admin";
}

export function canViewGlobalFeeRecap(role: Role): boolean {
  return role !== "freelance";
}

// Keep database IDs as the internal key, but show legacy JRS IDs in the current TRD format.
export function formatJobCode(id: string): string {
  const legacy = /^JRS-(\d+)$/.exec(id);
  return legacy ? `TRD-${legacy[1].padStart(4, "0")}` : id;
}

export type JobStatus =
  | "Belum Ditugaskan"
  | "Antre"
  | "Dikerjakan"
  | "Preview"
  | "MintaACC"
  | "Revisi"
  | "ACC"
  | "Finished"
  | "Dibatalkan";
export type JobPriority = "normal" | "express";
export type JobType = "Fullprint" | "Printing Depan Saja" | "Jersey + Celana" | "Jaket";

export interface Profile {
  id: string;
  name: string;
  avatarPath: string | null;
  whatsapp?: string | null;
  role: Role;
  isActive: boolean;
  lastSeen: string; // ISO
  availabilityStatus: "pending" | "ready" | "unavailable";
  availabilityUpdatedAt: string | null;
  registrationStatus: "pending" | "approved" | "rejected";
  registrationReviewReason?: string | null;
  isSimulatedAdmin?: boolean;
}

export interface FreelancerRegistrationRequest {
  profileId: string;
  name: string;
  email: string;
  whatsapp: string | null;
  requestedAt: string;
}

export interface AccountDirectoryEntry {
  profileId: string;
  email: string;
  emailConfirmedAt: string | null;
}

export interface FreelancerBankAccount {
  bankName: string;
  accountNumber: string;
  accountHolder: string;
}

export type FreelancerPaymentSchedule = "per_job" | "daily" | "weekly" | "monthly";

export interface FreelancerPaymentSetting {
  profileId: string;
  profileName: string;
  isActive: boolean;
  schedule: FreelancerPaymentSchedule;
  paymentMethod: "bank_transfer";
  bankName: string | null;
  accountNumber: string | null;
  accountHolder: string | null;
  updatedAt: string | null;
}

export interface FinanceMonthlyPaymentRow {
  profileId: string;
  profileName: string;
  openingBalance: number;
  earnedThisMonth: number;
  paidThisMonth: number;
  closingBalance: number;
  jobsFinishedThisMonth: number;
}

export interface FinanceUnpaidJob {
  jobId: string;
  teamName: string;
  jobType: JobType;
  finishedAt: string;
  earnedFee: number;
  paidAmount: number;
  dueAmount: number;
  totalRows: number;
}

export interface FinanceMonthlyJob {
  jobId: string;
  teamName: string;
  jobType: JobType;
  finishedAt: string;
  earnedFee: number;
  paidAmount: number;
  dueAmount: number;
  totalRows: number;
}

export interface FinancePaymentAllocation {
  jobId: string;
  teamName: string;
  amount: number;
}

export interface FinancePaymentHistoryRow {
  paymentId: string;
  recipientProfileId: string;
  recipientName: string;
  bankName: string | null;
  accountNumberLast4: string | null;
  accountHolder: string | null;
  amount: number;
  paidAt: string;
  bankReference: string;
  note: string;
  proofPath: string;
  status: "posted" | "voided";
  recordedBy: string;
  recordedAt: string;
  voidedBy: string | null;
  voidedAt: string | null;
  voidReason: string | null;
  allocations: FinancePaymentAllocation[];
  totalRows: number;
}

export interface FinancePaymentAuditRow {
  eventId: string;
  paymentRecordId: string | null;
  targetProfileId: string | null;
  targetName: string;
  actorName: string;
  eventType: "payment_recorded" | "payment_voided" | "payment_proof_viewed" | "bank_details_viewed" | "payment_schedule_updated";
  details: Record<string, unknown>;
  createdAt: string;
  totalRows: number;
}

export interface FreelancerBankAccountDetails {
  bankName: string;
  accountNumber: string;
  accountHolder: string;
}

export function validateFreelancerBankAccount(account: FreelancerBankAccount): string | null {
  const bankName = account.bankName.trim();
  const accountNumber = account.accountNumber.trim();
  const accountHolder = account.accountHolder.trim();
  if (bankName.length < 2 || bankName.length > 80) return "Nama bank wajib diisi (2–80 karakter).";
  const normalizedBank = bankName.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  if (/(^| )(go ?pay|ovo|dana|shopee ?pay|link ?aja|doku|sakuku|i ?saku|astra ?pay|motion ?pay|paytren|uangku)( |$)/.test(normalizedBank)) {
    return "Dompet digital tidak diperkenankan. Masukkan nama bank untuk rekening bank.";
  }
  if (!/^\d{5,30}$/.test(accountNumber)) return "Nomor rekening harus berisi 5–30 digit angka.";
  if (accountHolder.length < 2 || accountHolder.length > 100) return "Nama pemilik rekening wajib diisi (2–100 karakter).";
  return null;
}

export interface AdminAuditEvent {
  id: string;
  eventType: string;
  targetProfileId: string | null;
  targetLabel: string;
  actorProfileId: string | null;
  actorLabel: string;
  beforeData: Record<string, unknown>;
  afterData: Record<string, unknown>;
  reason: string;
  createdAt: string;
}

export interface JobFileMeta {
  id: string;
  jobId: string;
  name: string;
  path?: string; // object path Supabase Storage (bukan URL publik)
  fileKind: "PDF" | "CDR" | "PNG" | "JPEG" | "SVG" | "DOCX" | "XLSX" | "PPTX" | "AI" | "PSD";
  fileRole: "reference" | "result" | "preview" | "source";
  sizeBytes: number;
  uploadedBy: string;
  uploadedAt: string;
  lockedSubmissionId?: string; // terikat submission -> terkunci
}

export interface Submission {
  id: string;
  jobId: string;
  version: number;
  submissionType: "legacy" | "preview";
  fileIds: string[];
  note?: string;
  decision: "pending" | "approved" | "revision_requested";
  reviewNote?: string;
  submittedBy: string;
  submittedAt: string;
  reviewedBy?: string;
  reviewedAt?: string;
}

export interface JobEvent {
  id: string;
  jobId: string;
  actorId: string;
  actorName: string;
  type: string;
  fromStatus?: JobStatus;
  toStatus?: JobStatus;
  reason?: string;
  createdAt: string;
}

export interface Job {
  id: string; // TRD-XXXX (legacy JRS IDs remain valid)
  tim: string;
  jenis: JobType;
  qty: number;
  deadline: string; // ISO timestamptz
  fee: number;
  approvedFee?: number;
  approvedForProfileId?: string;
  assigneeId?: string;
  finishedAt?: string;
  status: JobStatus;
  priority: JobPriority;
  brief: string;
  ref?: string;
  currentSubmissionId?: string;
  approvedSubmissionId?: string;
  createdAt: string;
  antreSince?: string;
  cancelledAt?: string;
  cancelledBy?: string;
  cancellationReason?: string;
  revision: number;
}

export interface ChatMessage {
  id: string;
  threadId: string;
  senderId: string;
  senderName: string;
  text: string;
  createdAt: string;
}

export interface ChatThread {
  id: string;
  freelanceId: string;
  createdAt: string;
}

export const ACTIVE_STATUSES: JobStatus[] = ["Antre", "Dikerjakan", "Preview", "MintaACC", "Revisi", "ACC"];
export const TERMINAL_STATUSES: JobStatus[] = ["Finished", "Dibatalkan"];
export const ACCEPTED_KINDS = ["PDF", "CDR", "PNG", "JPEG", "SVG", "DOCX", "XLSX", "PPTX", "AI", "PSD"] as const;
export const ACCEPTED_FILE_EXTENSIONS = ".pdf,.cdr,.png,.jpg,.jpeg,.svg,.docx,.xlsx,.pptx,.ai,.psd";
export const MAX_FILE_BYTES = 1 * 1024 * 1024 * 1024; // 1 GiB
export const MAX_JOB_BYTES = 10 * 1024 * 1024 * 1024; // 10 GiB
export const PRESENCE_ONLINE_MS = 90_000;
export const HEARTBEAT_MS = 30_000;

export function isOnline(lastSeenIso: string, now = Date.now()): boolean {
  const age = now - new Date(lastSeenIso).getTime();
  return age >= 0 && age < PRESENCE_ONLINE_MS;
}

export function activeJobCount(jobs: Job[], profileId: string): number {
  return jobs.filter(
    (j) => j.assigneeId === profileId && ACTIVE_STATUSES.includes(j.status),
  ).length;
}

export function isFull(jobs: Job[], profileId: string, limit = 4): boolean {
  return activeJobCount(jobs, profileId) >= limit;
}

export function isUrgen(job: Job, slaHours: number, now = Date.now()): boolean {
  if (job.status !== "Antre" || !job.antreSince) return false;
  return now - new Date(job.antreSince).getTime() >= slaHours * 3600_000;
}

export function isTerlambat(job: Job, now = Date.now()): boolean {
  if (job.status === "Finished" || job.status === "Dibatalkan") return false;
  return now >= new Date(job.deadline).getTime();
}

// Preview is submitted from the file panel and reviewed by Admin; final CDR
// delivery moves an approved job to Finished.
export function allowedTransitions(
  job: Job,
  role: Role,
): { to: JobStatus; label: string }[] {
  if (TERMINAL_STATUSES.includes(job.status)) return [];
  if (role === "finance") return [];
  if (role === "freelance") {
    switch (job.status) {
      case "Antre":
        return [{ to: "Dikerjakan", label: "Mulai Kerjakan" }];
      case "Revisi":
        return [{ to: "Dikerjakan", label: "Lanjutkan pengerjaan" }];
      default:
        return [];
    }
  }
  // Admin reviews previews; only the assigned freelancer starts/resumes work.
  return [];
}

export function canAssign(
  jobs: Job[],
  targetProfile: Profile,
  now = Date.now(),
): { ok: boolean; reason?: string } {
  if (targetProfile.role !== "freelance") return { ok: false, reason: "Hanya ke Freelance" };
  if (!isOnline(targetProfile.lastSeen, now)) return { ok: false, reason: "Freelance offline (>=90 dtk)" };
  if (isFull(jobs, targetProfile.id)) return { ok: false, reason: "Freelance penuh (>=4 job aktif)" };
  return { ok: true };
}

export function validateFileKind(name: string): JobFileMeta["fileKind"] | null {
  const ext = name.split(".").pop()?.toUpperCase();
  if (ext === "JPG") return "JPEG";
  return ACCEPTED_KINDS.find((kind) => kind === ext) ?? null;
}

export function totalActiveBytes(files: JobFileMeta[]): number {
  return files.reduce((a, f) => a + f.sizeBytes, 0);
}

export function formatBytes(n: number): string {
  if (n >= 1024 ** 3) return `${(n / 1024 ** 3).toFixed(2)} GiB`;
  if (n >= 1024 ** 2) return `${(n / 1024 ** 2).toFixed(1)} MiB`;
  if (n >= 1024) return `${(n / 1024).toFixed(0)} KiB`;
  return `${n} B`;
}

export function formatWIB(iso: string): string {
  try {
    return new Intl.DateTimeFormat("id-ID", {
      timeZone: "Asia/Jakarta",
      day: "2-digit",
      month: "short",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    }).format(new Date(iso));
  } catch {
    return iso;
  }
}

export function uid(prefix: string): string {
  return `${prefix}-${Math.random().toString(36).slice(2, 8).toUpperCase()}`;
}
