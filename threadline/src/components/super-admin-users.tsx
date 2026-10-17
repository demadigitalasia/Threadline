"use client";

import { Fragment, useMemo, useState, type FormEvent } from "react";
import { ROLE_LABELS, ROLE_ORDER, formatWIB, type Profile, type Role } from "@/lib/domain";
import { useReadyStore } from "@/lib/store-context";
import type { Toast } from "./threadline-ui";
import { Select } from "./threadline-ui";
import { DatePicker } from "./date-picker";

type AccessDraft = { role: Role; isActive: boolean; reason: string };
type AccountEditorDraft = { profileId: string; name: string; whatsapp: string; email: string; password: string; confirmPassword: string; reason: string };
type AccountDeletionDraft = { profileId: string; name: string; email: string; confirmation: string; reason: string };
type AccountRole = Exclude<Role, "super_admin">;
type AccountAction = "password_reset" | "resend_verification" | "revoke_sessions";

const ACTION_LABELS: Record<AccountAction, string> = {
  password_reset: "Kirim tautan reset kata sandi",
  resend_verification: "Kirim ulang verifikasi email",
  revoke_sessions: "Keluar dari semua perangkat",
};

function snapshot(data: Record<string, unknown>) {
  const fieldLabels: Record<string, string> = {
    email: "Email",
    invitation_sent: "Undangan terkirim",
    is_active: "Akses aktif",
    max_active_jobs: "Batas job aktif",
    name: "Nama",
    password_changed: "Kata sandi diganti",
    registration_status: "Status pendaftaran",
    role: "Role",
    sla_hours: "SLA urgensi",
    whatsapp: "WhatsApp",
  };
  const valueLabels: Record<string, string> = {
    approved: "Disetujui",
    freelance: "Freelancer",
    pending: "Menunggu review",
    rejected: "Ditolak",
    admin: "Admin",
    finance: "Finance",
    super_admin: "Super Admin",
  };
  const values = Object.entries(data).filter(([, value]) => value !== null && value !== undefined);
  return values.length
    ? values.map(([key, value]) => {
      const rawValue = typeof value === "object" ? JSON.stringify(value) : String(value);
      const displayValue = typeof value === "boolean" ? (value ? "Ya" : "Tidak") : valueLabels[rawValue] ?? rawValue;
      return `${fieldLabels[key] ?? key.replaceAll("_", " ")}: ${displayValue}`;
    }).join(" · ")
    : "—";
}

function auditLabel(eventType: string) {
  const labels: Record<string, string> = {
    account_access_changed: "Akses akun diubah",
    account_created: "Akun dibuat",
    account_invited: "Akun diundang",
    account_updated: "Data akun diperbarui",
    freelancer_compensation_updated: "Skema pembayaran diperbarui",
    freelancer_payment_schedule_updated: "Jadwal pembayaran diperbarui",
    freelancer_registration_approved: "Pendaftaran freelancer disetujui",
    freelancer_registration_rejected: "Pendaftaran freelancer ditolak",
    account_deleted: "Akun dihapus",
    password_reset_email_sent: "Tautan reset kata sandi dikirim",
    sessions_revoked: "Sesi perangkat dicabut",
    settings_updated: "Pengaturan bersama diperbarui",
    verification_email_sent: "Email verifikasi dikirim",
  };
  return labels[eventType] ?? eventType.replaceAll("_", " ");
}

export function SuperAdminUsersPanel({ onToast }: { onToast: Toast }) {
  const { data, currentProfile, manageProfileAccess, refresh } = useReadyStore();
  const isSuperAdmin = currentProfile.role === "super_admin";
  const canDeleteAccounts = isSuperAdmin;
  const [drafts, setDrafts] = useState<Record<string, AccessDraft>>({});
  const [savingId, setSavingId] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [roleFilter, setRoleFilter] = useState("all");
  const [statusFilter, setStatusFilter] = useState("all");
  const [auditQuery, setAuditQuery] = useState("");
  const [auditType, setAuditType] = useState("all");
  const [auditFrom, setAuditFrom] = useState("");
  const [auditTo, setAuditTo] = useState("");
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [accountRole, setAccountRole] = useState<AccountRole>("freelance");
  const [accountPassword, setAccountPassword] = useState("");
  const [confirmAccountPassword, setConfirmAccountPassword] = useState("");
  const [accountReason, setAccountReason] = useState("");
  const [creatingAccount, setCreatingAccount] = useState(false);
  const [actionId, setActionId] = useState<string | null>(null);
  const [editingAccount, setEditingAccount] = useState<AccountEditorDraft | null>(null);
  const [savingAccount, setSavingAccount] = useState(false);
  const [deletingAccount, setDeletingAccount] = useState<AccountDeletionDraft | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [deletionError, setDeletionError] = useState("");

  const accountById = useMemo(() => new Map(data.accountDirectory.map((entry) => [entry.profileId, entry])), [data.accountDirectory]);
  const filteredProfiles = useMemo(() => {
    const normalized = query.trim().toLowerCase();
    return data.profiles.filter((profile) => {
      const account = accountById.get(profile.id);
      const searchable = `${profile.name} ${profile.id} ${account?.email ?? ""}`.toLowerCase();
      const matchesQuery = !normalized || searchable.includes(normalized);
      const matchesRole = roleFilter === "all" || profile.role === roleFilter;
      const matchesStatus = statusFilter === "all" || (statusFilter === "active" ? profile.isActive : !profile.isActive);
      return matchesQuery && matchesRole && matchesStatus;
    });
  }, [accountById, data.profiles, query, roleFilter, statusFilter]);
  const auditTypes = useMemo(() => [...new Set(data.adminAuditEvents.map((event) => event.eventType))], [data.adminAuditEvents]);
  const filteredAuditEvents = useMemo(() => {
    const normalized = auditQuery.trim().toLowerCase();
    return data.adminAuditEvents.filter((event) => {
      const text = `${event.targetLabel} ${event.actorLabel} ${event.reason} ${event.eventType} ${auditLabel(event.eventType)} ${snapshot(event.beforeData)} ${snapshot(event.afterData)}`.toLowerCase();
      const date = event.createdAt.slice(0, 10);
      return (!normalized || text.includes(normalized))
        && (auditType === "all" || event.eventType === auditType)
        && (!auditFrom || date >= auditFrom)
        && (!auditTo || date <= auditTo);
    });
  }, [auditFrom, auditQuery, auditTo, auditType, data.adminAuditEvents]);

  const updateDraft = (profile: Profile, patch: Partial<AccessDraft>) => {
    setDrafts((current) => ({
      ...current,
      [profile.id]: {
        role: current[profile.id]?.role ?? profile.role,
        isActive: current[profile.id]?.isActive ?? profile.isActive,
        reason: current[profile.id]?.reason ?? "",
        ...patch,
      },
    }));
  };

  const saveAccess = async (profile: Profile) => {
    const draft = drafts[profile.id] ?? { role: profile.role, isActive: profile.isActive, reason: "" };
    if (draft.role === "super_admin" && profile.role !== "super_admin" && !window.confirm(`Jadikan ${profile.name} sebagai Super Admin? Pengguna ini akan memperoleh akses penuh.`)) return;
    if (profile.isActive && !draft.isActive && !window.confirm(`Nonaktifkan akses ${profile.name}?`)) return;
    setSavingId(profile.id);
    const result = await manageProfileAccess(profile.id, draft.role, draft.isActive, draft.reason);
    setSavingId(null);
    if (!result.ok) {
      onToast(result.error ?? "Perubahan akses gagal");
      return;
    }
    setDrafts((current) => { const next = { ...current }; delete next[profile.id]; return next; });
    if (profile.isActive && !draft.isActive) {
      const response = await fetch(`/api/backend/super-admin/accounts/${profile.id}/actions`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ action: "revoke_sessions", reason: draft.reason }),
      });
      if (!response.ok) {
        onToast(`Akses ${profile.name} dinonaktifkan, tetapi sesi perangkat belum berhasil dicabut.`);
        refresh();
        return;
      }
    }
    onToast(`Akses ${profile.name} diperbarui dan dicatat`);
  };

  const createAccount = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (accountPassword !== confirmAccountPassword) {
      onToast("Konfirmasi kata sandi tidak sama.");
      return;
    }
    setCreatingAccount(true);
    try {
      const response = await fetch("/api/backend/super-admin/accounts", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name, email, role: accountRole, password: accountPassword, reason: accountReason }),
      });
      const result = await response.json() as { ok?: boolean; message?: string; error?: string };
      if (!response.ok) { onToast(result.error ?? "Akun gagal dibuat"); return; }
      setName(""); setEmail(""); setAccountRole("freelance"); setAccountPassword(""); setConfirmAccountPassword(""); setAccountReason("");
      refresh();
      onToast(result.message ?? "Akun berhasil dibuat");
    } catch {
      onToast("Tidak dapat terhubung untuk membuat akun");
    } finally {
      setCreatingAccount(false);
    }
  };

  const runAccountAction = async (profile: Profile, action: AccountAction) => {
    if (profile.id === currentProfile.id) return;
    if (action === "revoke_sessions" && !window.confirm(`Keluarkan ${profile.name} dari semua perangkat?`)) return;
    const reason = window.prompt(`Alasan: ${ACTION_LABELS[action].toLowerCase()}`)?.trim();
    if (!reason) return;
    setActionId(`${profile.id}:${action}`);
    try {
      const response = await fetch(`/api/backend/super-admin/accounts/${profile.id}/actions`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ action, reason }),
      });
      const result = await response.json() as { message?: string; error?: string };
      if (!response.ok) { onToast(result.error ?? "Tindakan akun gagal"); return; }
      refresh();
      onToast(result.message ?? "Tindakan akun berhasil");
    } catch {
      onToast("Tidak dapat terhubung untuk mengelola akun");
    } finally {
      setActionId(null);
    }
  };

  const openAccountEditor = (profile: Profile) => {
    const account = accountById.get(profile.id);
    setEditingAccount({
      profileId: profile.id,
      name: profile.name,
      whatsapp: profile.whatsapp ?? "",
      email: account?.email ?? "",
      password: "",
      confirmPassword: "",
      reason: "",
    });
  };

  const saveAccount = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!editingAccount) return;
    if (editingAccount.password && editingAccount.password !== editingAccount.confirmPassword) {
      onToast("Konfirmasi kata sandi tidak sama.");
      return;
    }
    setSavingAccount(true);
    try {
      const response = await fetch(`/api/backend/super-admin/accounts/${editingAccount.profileId}`, {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(editingAccount),
      });
      const result = await response.json() as { ok?: boolean; message?: string; error?: string; partial?: boolean };
      if (!response.ok) {
        if (result.partial) refresh();
        onToast(result.error ?? "Perubahan akun gagal disimpan");
        return;
      }
      setEditingAccount(null);
      refresh();
      onToast(result.message ?? "Data akun berhasil diperbarui");
    } catch {
      onToast("Tidak dapat terhubung untuk menyimpan akun");
    } finally {
      setSavingAccount(false);
    }
  };

  const deleteAccount = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!deletingAccount) return;
    if (deletingAccount.confirmation.trim().toLowerCase() !== deletingAccount.email.toLowerCase()) {
      onToast("Email konfirmasi belum cocok.");
      return;
    }
    setDeletionError("");
    setDeletingId(deletingAccount.profileId);
    try {
      const response = await fetch(`/api/backend/managed-accounts/${deletingAccount.profileId}`, {
        method: "DELETE",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ confirmation: deletingAccount.confirmation, reason: deletingAccount.reason }),
      });
      let result: { ok?: boolean; message?: string; error?: string; partial?: boolean };
      try {
        result = await response.json() as typeof result;
      } catch {
        setDeletionError(`Server gagal memproses penghapusan (HTTP ${response.status}). Coba muat ulang halaman.`);
        return;
      }
      if (!response.ok) {
        if (result.partial) {
          setDeletingAccount(null);
          refresh();
          onToast(result.error ?? "Akun berhasil dihapus, tetapi pencatatan audit gagal.");
        } else {
          setDeletionError(result.error ?? "Akun gagal dihapus.");
        }
        return;
      }
      setDeletingAccount(null);
      refresh();
      onToast(result.message ?? "Akun berhasil dihapus");
    } catch {
      setDeletionError("Tidak dapat terhubung ke server. Periksa koneksi lalu coba lagi.");
    } finally {
      setDeletingId(null);
    }
  };

  const openDeleteConfirmation = (profile: Profile) => {
    const account = accountById.get(profile.id);
    if (!canDeleteAccounts || profile.id === currentProfile.id || profile.role === "super_admin" || !account?.email) return;
    setDeletionError("");
    setDeletingAccount({ profileId: profile.id, name: profile.name, email: account.email, confirmation: "", reason: "" });
  };

  const activeCount = data.profiles.filter((profile) => profile.isActive).length;
  const roleOptions = [{ value: "all", label: "Semua role" }, ...ROLE_ORDER.map((role) => ({ value: role, label: ROLE_LABELS[role] }))];

  return (
    <div className="space-y-4">
      <section className="auth-side relative overflow-hidden rounded-3xl p-5 text-white sm:p-6">
        <p className="text-[10px] font-bold uppercase tracking-[0.2em] text-white/65">Kontrol akses</p>
        <div className="mt-2 flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-extrabold tracking-tight sm:text-3xl">Manajemen Pengguna</h1>
            <p className="mt-1 max-w-2xl text-sm text-white/75">Buat akun tim, atur akses, dan telusuri perubahan yang dilakukan di Threadline.</p>
          </div>
          <div className="flex gap-2 text-xs font-semibold">
            <span className="rounded-full bg-white/12 px-3 py-1.5 ring-1 ring-inset ring-white/20">{data.profiles.length} akun</span>
            <span className="rounded-full bg-emerald-300/15 px-3 py-1.5 text-emerald-50 ring-1 ring-inset ring-emerald-100/25">{activeCount} aktif</span>
          </div>
        </div>
      </section>

      {isSuperAdmin && <section className="glass-card p-4 sm:p-5">
        <div>
          <h2 className="text-base font-bold">Buat akun pengguna</h2>
          <p className="mt-1 text-xs text-zinc-500">Akun langsung aktif tanpa email undangan. Atur kata sandi awal, lalu berikan detail login kepada pengguna.</p>
        </div>
        <form className="mt-4 grid gap-3 md:grid-cols-2" onSubmit={(event) => { void createAccount(event); }}>
          <label className="text-xs font-semibold text-zinc-700">Nama lengkap
            <input className="input mt-1 block w-full px-3 py-2 text-sm" value={name} onChange={(event) => setName(event.target.value)} minLength={3} maxLength={100} required />
          </label>
          <label className="text-xs font-semibold text-zinc-700">Email login
            <input className="input mt-1 block w-full px-3 py-2 text-sm" type="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} required />
          </label>
          <label className="text-xs font-semibold text-zinc-700">Kata sandi awal (minimal 8 karakter)
            <input className="input mt-1 block w-full px-3 py-2 text-sm" type="password" autoComplete="new-password" value={accountPassword} onChange={(event) => setAccountPassword(event.target.value)} minLength={8} maxLength={128} required />
          </label>
          <label className="text-xs font-semibold text-zinc-700">Konfirmasi kata sandi
            <input className="input mt-1 block w-full px-3 py-2 text-sm" type="password" autoComplete="new-password" value={confirmAccountPassword} onChange={(event) => setConfirmAccountPassword(event.target.value)} minLength={8} maxLength={128} required />
          </label>
          <label className="text-xs font-semibold text-zinc-700">Role akun
            <Select ariaLabel="Role akun baru" value={accountRole} onChange={(value) => setAccountRole(value as AccountRole)} options={ROLE_ORDER.filter((role) => role !== "super_admin").map((role) => ({ value: role, label: ROLE_LABELS[role] }))} />
          </label>
          <label className="text-xs font-semibold text-zinc-700">Alasan pembuatan akun
            <input className="input mt-1 block w-full px-3 py-2 text-sm" value={accountReason} onChange={(event) => setAccountReason(event.target.value)} placeholder="Contoh: penambahan staf Finance" maxLength={500} required />
          </label>
          <div className="md:col-span-2">
            <button className="btn-primary rounded-xl px-4 py-2.5 text-sm font-semibold text-white disabled:opacity-50" disabled={creatingAccount}>
              {creatingAccount ? "Membuat akun…" : "Buat akun"}
            </button>
          </div>
        </form>
      </section>}

      <section className="glass-card p-4 sm:p-5">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h2 className="text-base font-bold">Semua akun</h2>
            <p className="mt-1 text-xs text-zinc-500">{isSuperAdmin ? "Atur akses dan data akun. Akun nonaktif tetap tersimpan untuk menjaga riwayat pekerjaan." : "Fitur manajemen akun ini khusus Super Admin."}</p>
          </div>
          <div className="grid w-full gap-2 sm:w-auto sm:grid-cols-[minmax(220px,1fr)_160px_145px]">
            <input className="input px-3 py-2 text-sm" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Cari nama, email, atau ID" aria-label="Cari pengguna" />
            <Select ariaLabel="Filter role" value={roleFilter} onChange={setRoleFilter} options={roleOptions} />
            <Select ariaLabel="Filter status akun" value={statusFilter} onChange={setStatusFilter} options={[{ value: "all", label: "Semua status" }, { value: "active", label: "Aktif" }, { value: "inactive", label: "Nonaktif" }]} />
          </div>
        </div>
        <div className="mt-4 overflow-x-auto rounded-2xl ring-1 ring-inset ring-zinc-200/80">
          <table className="w-full min-w-[1040px] border-collapse text-left">
            <thead className="bg-zinc-50/90 text-[10px] uppercase tracking-wider text-zinc-500">
              <tr>
                <th className="px-4 py-3 font-bold">Akun</th>
                <th className="w-44 px-3 py-3 font-bold">Role</th>
                <th className="w-32 px-3 py-3 font-bold">{isSuperAdmin ? "Akses" : "Status"}</th>
                <th className="w-48 px-3 py-3 font-bold">Aktivitas</th>
                <th className="w-[340px] px-3 py-3 font-bold">Kelola</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-100 bg-white/70">
              {filteredProfiles.map((profile) => {
                const account = accountById.get(profile.id);
                const draft = drafts[profile.id] ?? { role: profile.role, isActive: profile.isActive, reason: "" };
                const changed = draft.role !== profile.role || draft.isActive !== profile.isActive;
                return (
                  <Fragment key={profile.id}>
                    <tr className="align-middle">
                      <td className="max-w-[360px] px-4 py-3">
                        <div className="flex flex-wrap items-center gap-2">
                          <p className="truncate text-sm font-bold text-zinc-900">{profile.name}{profile.id === currentProfile.id ? " (Anda)" : ""}</p>
                          <span className={`rounded-full px-2 py-0.5 text-[10px] font-bold ${profile.isActive ? "bg-emerald-50 text-emerald-800" : "bg-zinc-100 text-zinc-600"}`}>{profile.isActive ? "Aktif" : "Nonaktif"}</span>
                        </div>
                        <p className="mt-1 break-all text-xs text-zinc-600">{account?.email || "Email tidak tersedia"}</p>
                        <p className="mt-1 text-[11px] text-zinc-500">WA: {profile.whatsapp || "Belum diisi"}</p>
                      </td>
                      <td className="px-3 py-3">{isSuperAdmin
                        ? <Select ariaLabel={`Role ${profile.name}`} value={draft.role} disabled={profile.id === currentProfile.id} onChange={(value) => updateDraft(profile, { role: value as Role })} options={ROLE_ORDER.map((role) => ({ value: role, label: ROLE_LABELS[role] }))} />
                        : <span className="inline-flex rounded-full bg-indigo-50 px-2.5 py-1 text-xs font-semibold text-indigo-700">{ROLE_LABELS[profile.role]}</span>}
                      </td>
                      <td className="px-3 py-3">
                        {isSuperAdmin
                          ? <label className="flex items-center gap-2 text-xs font-semibold text-zinc-700">
                            <input type="checkbox" className="accent-violet-600" checked={draft.isActive} disabled={profile.id === currentProfile.id} onChange={(event) => updateDraft(profile, { isActive: event.target.checked })} />
                            Aktif
                          </label>
                          : <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${profile.isActive ? "bg-emerald-50 text-emerald-700" : "bg-zinc-100 text-zinc-600"}`}>{profile.isActive ? "Aktif" : "Nonaktif"}</span>}
                      </td>
                      <td className="px-3 py-3 text-[11px] leading-5 text-zinc-500">
                        <p>{account?.emailConfirmedAt ? "Email terverifikasi" : "Belum terverifikasi"}</p>
                        <p>Terakhir aktif {formatWIB(profile.lastSeen)}</p>
                      </td>
                      <td className="px-3 py-3">
                        <div className="flex flex-wrap gap-1.5">
                          {isSuperAdmin && <button className="btn-primary rounded-lg px-2.5 py-1.5 text-xs font-semibold text-white" onClick={() => openAccountEditor(profile)}>Edit akun</button>}
                          {isSuperAdmin && profile.id !== currentProfile.id && <>
                            <button className="btn-ghost rounded-lg px-2.5 py-1.5 text-xs font-semibold" disabled={actionId !== null} onClick={() => { void runAccountAction(profile, "password_reset"); }}>Reset sandi</button>
                            {!account?.emailConfirmedAt && <button className="btn-ghost rounded-lg px-2.5 py-1.5 text-xs font-semibold" disabled={actionId !== null} onClick={() => { void runAccountAction(profile, "resend_verification"); }}>Kirim verifikasi</button>}
                            <button className="btn-ghost rounded-lg px-2.5 py-1.5 text-xs font-semibold text-rose-700" disabled={actionId !== null} onClick={() => { void runAccountAction(profile, "revoke_sessions"); }}>
                              {actionId === `${profile.id}:revoke_sessions` ? "Mengeluarkan…" : "Cabut sesi"}
                            </button>
                          </>}
                          {canDeleteAccounts && profile.id !== currentProfile.id && profile.role !== "super_admin" && <button className="rounded-lg border border-rose-200 bg-rose-50 px-2.5 py-1.5 text-xs font-semibold text-rose-700 transition hover:bg-rose-100 disabled:opacity-50" disabled={deletingId !== null || !account?.email} onClick={() => openDeleteConfirmation(profile)}>
                            {deletingId === profile.id ? "Menghapus…" : "Hapus akun"}
                          </button>}
                        </div>
                      </td>
                    </tr>
                    {isSuperAdmin && changed && <tr><td colSpan={5} className="bg-violet-50/50 px-4 py-3">
                      <div className="flex flex-wrap gap-2">
                        <input className="input min-w-52 flex-1 px-3 py-2 text-xs" value={draft.reason} onChange={(event) => updateDraft(profile, { reason: event.target.value })} placeholder="Alasan perubahan wajib diisi" />
                        <button className="btn-primary rounded-xl px-3 py-2 text-xs font-semibold text-white disabled:opacity-40" disabled={!draft.reason.trim() || savingId === profile.id} onClick={() => { void saveAccess(profile); }}>
                          {savingId === profile.id ? "Menyimpan…" : "Simpan akses"}
                        </button>
                      </div>
                    </td></tr>}
                  </Fragment>
                );
              })}
              {filteredProfiles.length === 0 && <tr><td colSpan={5} className="px-4 py-8 text-center text-sm text-zinc-500">Tidak ada akun yang sesuai.</td></tr>}
            </tbody>
          </table>
        </div>
        {isSuperAdmin && <p className="mt-3 text-[11px] text-zinc-500">Super Admin aktif terakhir tidak dapat diturunkan atau dinonaktifkan. Semua perubahan akses perlu alasan.</p>}
      </section>

      {isSuperAdmin && <section className="glass-card p-4 sm:p-5">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex min-w-0 items-center gap-3">
            <span className="grid size-10 shrink-0 place-items-center rounded-xl bg-gradient-to-br from-violet-600 to-indigo-500 text-white shadow-md shadow-indigo-500/20" aria-hidden>
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M12 3 19 6v5c0 4.5-2.9 7.6-7 10-4.1-2.4-7-5.5-7-10V6l7-3Z" /><path d="m9 12 2 2 4-4" /></svg>
            </span>
            <div className="min-w-0">
              <h2 className="text-base font-bold">Riwayat keamanan</h2>
              <p className="mt-0.5 text-xs text-zinc-500">Pembuatan akun, perubahan akses, dan keputusan Admin.</p>
            </div>
          </div>
          <span className="rounded-full bg-violet-50 px-3 py-1.5 text-xs font-bold text-violet-700 ring-1 ring-inset ring-violet-100">
            {filteredAuditEvents.length} aktivitas
          </span>
        </div>
        <div className="mt-4 rounded-2xl border border-zinc-200/70 bg-zinc-50/75 p-3">
          <div className="grid gap-3 sm:grid-cols-2 2xl:grid-cols-5">
            <label className="text-[11px] font-semibold text-zinc-600 2xl:col-span-2">Cari aktivitas
              <input className="input mt-1 h-10 w-full px-3 text-sm" value={auditQuery} onChange={(event) => setAuditQuery(event.target.value)} placeholder="Target, pelaku, atau alasan" aria-label="Cari riwayat keamanan" />
            </label>
            <label className="text-[11px] font-semibold text-zinc-600">Jenis aktivitas
              <Select className="mt-1 [&>button]:h-10" ariaLabel="Filter jenis peristiwa" value={auditType} onChange={setAuditType} options={[{ value: "all", label: "Semua tindakan" }, ...auditTypes.map((eventType) => ({ value: eventType, label: auditLabel(eventType) }))]} />
            </label>
            <div className="text-[11px] font-semibold text-zinc-600"><label htmlFor="audit-from">Dari tanggal</label><div className="mt-1 [&>button]:h-10"><DatePicker id="audit-from" ariaLabel="Filter dari tanggal" value={auditFrom} onChange={setAuditFrom} /></div></div>
            <div className="text-[11px] font-semibold text-zinc-600"><label htmlFor="audit-to">Sampai tanggal</label><div className="mt-1 [&>button]:h-10"><DatePicker id="audit-to" ariaLabel="Filter sampai tanggal" value={auditTo} onChange={setAuditTo} /></div></div>
          </div>
        </div>
        <div className="mt-4 overflow-hidden rounded-2xl border border-zinc-200/80 bg-white/65">
          {filteredAuditEvents.map((event) => (
            <article key={event.id} className="border-b border-zinc-100 px-4 py-4 last:border-b-0 sm:px-5">
              <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
                <div className="flex min-w-0 flex-wrap items-center gap-2">
                  <span className="rounded-lg bg-indigo-50 px-2.5 py-1 text-xs font-bold text-indigo-700 ring-1 ring-inset ring-indigo-100">{auditLabel(event.eventType)}</span>
                  <span className="text-xs text-zinc-500">Target: <b className="font-semibold text-zinc-800">{event.targetLabel}</b></span>
                  <span className="hidden text-zinc-300 sm:inline">·</span>
                  <span className="text-xs text-zinc-500">Pelaku: <b className="font-semibold text-zinc-800">{event.actorLabel}</b></span>
                </div>
                <time className="shrink-0 text-[11px] font-medium text-zinc-500">{formatWIB(event.createdAt)}</time>
              </div>
              {(Object.keys(event.beforeData).length > 0 || Object.keys(event.afterData).length > 0) && (
                <div className="mt-3 grid gap-2 md:grid-cols-2">
                  {Object.keys(event.beforeData).length > 0 && <div className="min-w-0 rounded-xl bg-zinc-50 px-3 py-2.5 ring-1 ring-inset ring-zinc-200/70">
                    <p className="text-[10px] font-bold uppercase tracking-wider text-zinc-400">Sebelum</p>
                    <p className="mt-1 break-words text-xs leading-5 text-zinc-600">{snapshot(event.beforeData)}</p>
                  </div>}
                  {Object.keys(event.afterData).length > 0 && <div className="min-w-0 rounded-xl bg-emerald-50/60 px-3 py-2.5 ring-1 ring-inset ring-emerald-100">
                    <p className="text-[10px] font-bold uppercase tracking-wider text-emerald-700/65">Sesudah</p>
                    <p className="mt-1 break-words text-xs leading-5 text-zinc-700">{snapshot(event.afterData)}</p>
                  </div>}
                </div>
              )}
              <div className="mt-3 flex gap-2 rounded-xl bg-violet-50/60 px-3 py-2 text-xs leading-5 text-zinc-600 ring-1 ring-inset ring-violet-100/80">
                <span className="shrink-0 font-bold text-violet-700">Alasan</span>
                <p className="min-w-0 break-words">{event.reason}</p>
              </div>
            </article>
          ))}
          {filteredAuditEvents.length === 0 && <div className="px-4 py-10 text-center">
            <span className="mx-auto grid size-10 place-items-center rounded-full bg-zinc-100 text-zinc-400" aria-hidden>
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><circle cx="11" cy="11" r="7" /><path d="m20 20-4-4" /></svg>
            </span>
            <p className="mt-3 text-sm font-semibold text-zinc-700">Tidak ada aktivitas yang cocok</p>
            <p className="mt-1 text-xs text-zinc-500">Coba ubah kata pencarian atau rentang tanggal.</p>
          </div>}
        </div>
      </section>}

      {editingAccount && <div className="fixed inset-0 z-[80] flex items-center justify-center overflow-y-auto bg-zinc-950/45 p-4 backdrop-blur-sm" onMouseDown={(event) => { if (event.target === event.currentTarget && !savingAccount) setEditingAccount(null); }}>
        <section role="dialog" aria-modal="true" aria-labelledby="edit-account-title" className="glass-card-gradient my-auto w-full max-w-2xl overflow-hidden rounded-3xl shadow-2xl">
          <div className="border-b border-violet-100/80 px-5 py-4 sm:px-6">
            <p className="text-[10px] font-bold uppercase tracking-[0.18em] text-violet-600">Manajemen akun</p>
            <h2 id="edit-account-title" className="mt-1 text-xl font-extrabold">Edit akun</h2>
            <p className="mt-1 text-xs text-zinc-500">Kata sandi boleh dikosongkan jika tidak ingin menggantinya.</p>
          </div>
          <form className="space-y-4 p-5 sm:p-6" onSubmit={(event) => { void saveAccount(event); }}>
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="text-xs font-semibold text-zinc-700">Nama lengkap
                <input className="input mt-1 block w-full px-3 py-2 text-sm" autoComplete="name" minLength={3} maxLength={100} required value={editingAccount.name} onChange={(event) => setEditingAccount((current) => current ? { ...current, name: event.target.value } : current)} />
              </label>
              <label className="text-xs font-semibold text-zinc-700">No. WhatsApp
                <input className="input mt-1 block w-full px-3 py-2 text-sm" type="tel" autoComplete="tel" maxLength={24} placeholder="Contoh: +62 812..." value={editingAccount.whatsapp} onChange={(event) => setEditingAccount((current) => current ? { ...current, whatsapp: event.target.value } : current)} />
              </label>
              <label className="text-xs font-semibold text-zinc-700 sm:col-span-2">Email login
                <input className="input mt-1 block w-full px-3 py-2 text-sm" type="email" autoComplete="email" required value={editingAccount.email} onChange={(event) => setEditingAccount((current) => current ? { ...current, email: event.target.value } : current)} />
              </label>
              <label className="text-xs font-semibold text-zinc-700">Kata sandi baru (opsional)
                <input className="input mt-1 block w-full px-3 py-2 text-sm" type="password" autoComplete="new-password" minLength={8} maxLength={128} value={editingAccount.password} onChange={(event) => setEditingAccount((current) => current ? { ...current, password: event.target.value } : current)} />
              </label>
              <label className="text-xs font-semibold text-zinc-700">Konfirmasi kata sandi
                <input className="input mt-1 block w-full px-3 py-2 text-sm" type="password" autoComplete="new-password" minLength={editingAccount.password ? 8 : undefined} maxLength={128} value={editingAccount.confirmPassword} onChange={(event) => setEditingAccount((current) => current ? { ...current, confirmPassword: event.target.value } : current)} />
              </label>
            </div>
            <label className="block text-xs font-semibold text-zinc-700">Alasan perubahan
              <textarea className="input mt-1 block w-full px-3 py-2 text-sm" rows={2} maxLength={500} required placeholder="Dicatat pada riwayat keamanan" value={editingAccount.reason} onChange={(event) => setEditingAccount((current) => current ? { ...current, reason: event.target.value } : current)} />
            </label>
            <div className="flex justify-end gap-2 border-t border-zinc-100 pt-4">
              <button type="button" className="btn-ghost rounded-xl px-4 py-2 text-sm font-semibold" disabled={savingAccount} onClick={() => setEditingAccount(null)}>Batal</button>
              <button className="btn-primary rounded-xl px-4 py-2 text-sm font-semibold text-white disabled:opacity-50" disabled={savingAccount || !editingAccount.reason.trim()}>
                {savingAccount ? "Menyimpan…" : "Simpan perubahan"}
              </button>
            </div>
          </form>
        </section>
      </div>}

      {deletingAccount && <div className="fixed inset-0 z-[90] flex items-center justify-center overflow-y-auto bg-zinc-950/55 p-4 backdrop-blur-sm" onMouseDown={(event) => { if (event.target === event.currentTarget && deletingId === null) setDeletingAccount(null); }}>
        <section role="dialog" aria-modal="true" aria-labelledby="delete-account-title" className="my-auto w-full max-w-lg overflow-hidden rounded-3xl border border-rose-200 bg-white shadow-2xl shadow-rose-950/20">
          <div className="bg-gradient-to-r from-rose-600 via-red-700 to-zinc-950 px-5 py-4 text-white sm:px-6">
            <p className="text-[10px] font-bold uppercase tracking-[0.18em] text-white/75">Hapus akun</p>
            <h2 id="delete-account-title" className="mt-1 text-xl font-extrabold">Hapus {deletingAccount.name}?</h2>
          </div>
          <form className="space-y-4 p-5 sm:p-6" onSubmit={(event) => { void deleteAccount(event); }}>
            <div className="rounded-2xl border border-rose-100 bg-rose-50/80 p-3 text-sm leading-6 text-rose-950">
              <p>Akun dan akses loginnya akan dihapus permanen. Tindakan ini dicatat dalam riwayat keamanan.</p>
              <p className="mt-1 text-xs text-rose-800">Akun yang masih tercatat pada pekerjaan berstatus ACC tidak dapat dihapus. Nonaktifkan aksesnya untuk mempertahankan riwayat pekerjaan.</p>
            </div>
            {deletionError && <p role="alert" className="rounded-xl border border-rose-200 bg-rose-50 px-3 py-2.5 text-sm leading-5 text-rose-800">{deletionError}</p>}
            <p className="break-all text-xs text-zinc-600">Email akun: <b className="text-zinc-900">{deletingAccount.email}</b></p>
            <label className="block text-xs font-semibold text-zinc-700">Alasan penghapusan
              <textarea className="input mt-1 block w-full px-3 py-2 text-sm" rows={2} maxLength={500} required placeholder="Contoh: akun sudah tidak digunakan" value={deletingAccount.reason} onChange={(event) => setDeletingAccount((current) => current ? { ...current, reason: event.target.value } : current)} />
            </label>
            <label className="block text-xs font-semibold text-zinc-700">Ketik email akun untuk mengonfirmasi
              <input className="input mt-1 block w-full px-3 py-2 text-sm" type="email" autoComplete="off" required value={deletingAccount.confirmation} onChange={(event) => setDeletingAccount((current) => current ? { ...current, confirmation: event.target.value } : current)} />
            </label>
            <div className="flex justify-end gap-2 border-t border-zinc-100 pt-4">
              <button type="button" className="btn-ghost rounded-xl px-4 py-2 text-sm font-semibold" disabled={deletingId !== null} onClick={() => setDeletingAccount(null)}>Batal</button>
              <button className="rounded-xl bg-gradient-to-r from-rose-600 to-red-800 px-4 py-2 text-sm font-semibold text-white shadow-md shadow-rose-900/20 disabled:cursor-not-allowed disabled:opacity-50" disabled={deletingId !== null || !deletingAccount.reason.trim() || deletingAccount.confirmation.trim().toLowerCase() !== deletingAccount.email.toLowerCase()}>
                {deletingId === deletingAccount.profileId ? "Menghapus…" : "Hapus permanen"}
              </button>
            </div>
          </form>
        </section>
      </div>}
    </div>
  );
}
