"use client";

import Image from "next/image";
import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { useReadyStore } from "@/lib/store-context";
import { activeJobCount, canViewGlobalFeeRecap, formatWIB, hasOperationsAccess, isOnline, ROLE_LABELS } from "@/lib/domain";
import { useNow } from "./threadline-ui";
import { FreelancerBankAccountForm } from "./freelancer-bank-account";
import type { Toast } from "./threadline-ui";

export function AkunPanel({ onToast }: { onToast: Toast }) {
  const { data, currentProfile, renameProfile, saveProfilePhoto, setFreelancerAvailability, signOut, userEmail } = useReadyStore();
  const router = useRouter();
  const [name, setName] = useState(currentProfile.name);
  const [saving, setSaving] = useState(false);
  const [savingPhoto, setSavingPhoto] = useState(false);
  const [savingAvailability, setSavingAvailability] = useState(false);
  const photoInput = useRef<HTMLInputElement>(null);
  const now = useNow();
  const online = isOnline(currentProfile.lastSeen, now);
  const initial = (currentProfile.name.trim()[0] ?? "?").toUpperCase();

  const myJobs = data.jobs.filter((j) => j.assigneeId === currentProfile.id);
  const myActive = activeJobCount(data.jobs, currentProfile.id);
  const myFinished = myJobs.filter((j) => j.status === "Finished");
  const myFee = myFinished.reduce((a, j) => a + (j.approvedFee ?? j.fee), 0);
  const myActivity = data.events
    .filter((e) => e.actorId === currentProfile.id)
    .sort((a, b) => +new Date(b.createdAt) - +new Date(a.createdAt))
    .slice(0, 6);
  const roleMetrics = currentProfile.role === "finance"
    ? [
      { label: "Rekap", value: "Bulanan" },
      { label: "Metode", value: "Transfer manual" },
      { label: "Alokasi", value: "Per job" },
      { label: "Histori", value: "Diaudit" },
    ]
    : [
      { label: hasOperationsAccess(currentProfile.role) ? "Job terlihat" : "Job saya", value: String(hasOperationsAccess(currentProfile.role) ? data.jobs.length : myJobs.length) },
      { label: "Aktif", value: `${myActive}/${data.maxActive}` },
      { label: "Job Finished", value: String(hasOperationsAccess(currentProfile.role) ? data.jobs.filter((job) => job.status === "Finished").length : myFinished.length) },
      { label: "Total fee Finished", value: `Rp${(canViewGlobalFeeRecap(currentProfile.role) ? data.jobs.filter((job) => job.status === "Finished").reduce((sum, job) => sum + (job.approvedFee ?? job.fee), 0) : myFee).toLocaleString("id-ID")}` },
    ];

  const capabilities = currentProfile.role === "super_admin"
    ? ["Seluruh akses operasional Admin", "Mengelola role dan status akses pengguna", "Melihat rekap fee setelah file asli dikirim", "Menjaga perubahan akun tercatat di audit"]
    : currentProfile.role === "finance"
      ? ["Mencatat transfer beserta tanggal, referensi, dan bukti", "Mengalokasikan transfer ke satu atau beberapa job Finished", "Melihat saldo kewajiban dan rekap bulanan", "Melihat rekening freelancer; pembukaan nomor penuh dicatat", "Mengatur jadwal pembayaran", "Tidak mengubah harga job atau status pekerjaan", "Mengubah nama kerja sendiri"]
      : currentProfile.role === "admin"
        ? ["Membuat, menugaskan & mengalihkan job", "Menyetujui preview atau meminta revisi", "Membatalkan job nonterminal", "Mengubah SLA & batas kapasitas", "Membaca semua thread chat", "Melihat rekap fee"]
        : ["Memulai job yang ditugaskan", "Mengunggah gambar preview untuk ditinjau Admin", "Mengirim file asli CDR setelah preview di-ACC", "Chat langsung dengan Admin dan Super Admin", "Mengubah nama kerja sendiri"];

  const saveName = () => {
    if (name.trim() === currentProfile.name) { onToast("Nama tidak berubah"); return; }
    setSaving(true);
    void renameProfile(name).then((r) => {
      setSaving(false);
      onToast(r.ok ? "Nama diubah, relasi tetap" : (r.error ?? "Gagal"));
    });
  };

  const changeAvailability = async (status: "ready" | "unavailable") => {
    setSavingAvailability(true);
    try {
      const result = await setFreelancerAvailability(status);
      onToast(result.ok
        ? status === "ready" ? "Status siap menerima job aktif" : "Status tidak siap menerima job aktif"
        : (result.error ?? "Status kesiapan gagal diubah"));
    } catch {
      onToast("Koneksi terputus. Status kesiapan belum berubah.");
    } finally {
      setSavingAvailability(false);
    }
  };

  return (
    <div className="space-y-3">
      {/* Hero profil */}
      <div className="auth-side relative overflow-hidden rounded-3xl p-5 text-white sm:p-6">
        <div className="relative flex flex-wrap items-center gap-4">
          <div className="flex shrink-0 flex-col items-center gap-1.5">
            <span className="relative flex h-16 w-16 items-center justify-center overflow-hidden rounded-3xl bg-gradient-to-br from-amber-300 to-rose-400 text-2xl font-extrabold text-indigo-950 shadow-lg" aria-hidden>
              {data.profilePhotoUrl ? <Image src={data.profilePhotoUrl} alt="" width={64} height={64} unoptimized className="h-full w-full object-cover" /> : initial}
            </span>
            {currentProfile.role === "freelance" && (
              <>
                <input
                  ref={photoInput}
                  type="file"
                  accept="image/jpeg,image/png,image/webp"
                  className="sr-only"
                  aria-label="Pilih foto profil"
                  disabled={savingPhoto}
                  onChange={(event) => {
                    const input = event.currentTarget;
                    const file = input.files?.[0];
                    if (!file) return;
                    setSavingPhoto(true);
                    void saveProfilePhoto(file).then((result) => {
                      onToast(result.ok ? "Foto profil berhasil diperbarui" : (result.error ?? "Foto profil gagal diperbarui"));
                    }).catch(() => {
                      onToast("Koneksi terputus. Foto profil belum berubah.");
                    }).finally(() => {
                      setSavingPhoto(false);
                      input.value = "";
                    });
                  }}
                />
                <button
                  type="button"
                  disabled={savingPhoto}
                  onClick={() => photoInput.current?.click()}
                  className="rounded-full bg-white/15 px-2.5 py-1 text-[11px] font-semibold text-white ring-1 ring-inset ring-white/25 transition hover:bg-white/25 disabled:opacity-60"
                >
                  {savingPhoto ? "Mengunggah…" : "Ganti foto"}
                </button>
              </>
            )}
          </div>
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-2">
              <h2 className="truncate text-xl font-extrabold tracking-tight sm:text-2xl">{currentProfile.name}</h2>
              <span className="rounded-full bg-white/15 px-2.5 py-0.5 text-[11px] font-bold uppercase tracking-widest ring-1 ring-inset ring-white/25">
                {ROLE_LABELS[currentProfile.role]}
              </span>
              <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-[11px] font-bold ring-1 ring-inset ${online ? "bg-emerald-300/20 text-emerald-100 ring-emerald-200/40" : "bg-white/10 text-white/70 ring-white/20"}`}>
                <span className={`h-1.5 w-1.5 rounded-full ${online ? "bg-emerald-300" : "bg-white/50"}`} />
                {online ? "Online" : "Offline"}
              </span>
            </div>
            <p className="mt-1 truncate text-sm text-white/75">{userEmail ?? "-"}</p>
          </div>
        </div>
        <div className="relative mt-5 grid grid-cols-2 gap-2 sm:grid-cols-4">
          {roleMetrics.map((s) => (
            <div key={s.label} className="auth-feature px-3 py-2.5">
              <div className="truncate text-base font-extrabold tabular-nums sm:text-lg">{s.value}</div>
              <div className="text-[11px] font-medium uppercase tracking-widest text-white/65">{s.label}</div>
            </div>
          ))}
        </div>
      </div>

      <div className="grid gap-3 lg:grid-cols-2">
        {/* Profil */}
        <div className="glass-card p-4 sm:p-5">
          <div className="text-sm font-bold">Nama profil</div>
          <p className="mt-0.5 text-xs text-zinc-500">Nama ini tampil di penugasan, chat, dan riwayat. Email dan WhatsApp tidak dapat diubah.</p>
          <div className="mt-3 flex gap-2">
            <input
              className="input flex-1 px-3 py-2 text-sm" value={name}
              onChange={(e) => setName(e.target.value)} placeholder="Nama lengkap"
              minLength={3}
              onKeyDown={(e) => { if (e.key === "Enter") saveName(); }}
            />
            <button className="btn-primary shrink-0 rounded-xl px-4 py-2 text-sm font-semibold text-white" disabled={saving} onClick={saveName}>
              {saving ? "Menyimpan…" : "Simpan"}
            </button>
          </div>
        </div>

        {currentProfile.role === "freelance" && (
          <div className="glass-card p-4 sm:p-5">
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div>
                <div className="text-sm font-bold">Kesiapan menerima job</div>
                <p className="mt-0.5 text-xs text-zinc-500">Status ini terlihat oleh Admin dan Super Admin, serta bisa diubah kapan saja.</p>
              </div>
              <span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ring-1 ring-inset ${currentProfile.availabilityStatus === "ready" ? "bg-emerald-50 text-emerald-800 ring-emerald-200" : currentProfile.availabilityStatus === "pending" ? "bg-indigo-50 text-indigo-800 ring-indigo-200" : "bg-zinc-100 text-zinc-600 ring-zinc-200"}`}>
                {currentProfile.availabilityStatus === "ready" ? "Siap menerima job" : currentProfile.availabilityStatus === "pending" ? "Belum check-in" : "Tidak siap"}
              </span>
            </div>
            <div className="mt-3 flex flex-wrap gap-2">
              <button
                type="button"
                disabled={savingAvailability || currentProfile.availabilityStatus === "ready"}
                onClick={() => { void changeAvailability("ready"); }}
                className="rounded-xl border border-emerald-200 bg-emerald-50 px-3.5 py-2 text-sm font-semibold text-emerald-800 hover:bg-emerald-100 disabled:opacity-50"
              >
                Siap menerima job
              </button>
              <button
                type="button"
                disabled={savingAvailability || currentProfile.availabilityStatus === "unavailable"}
                onClick={() => { void changeAvailability("unavailable"); }}
                className="btn-ghost rounded-xl px-3.5 py-2 text-sm font-semibold disabled:opacity-50"
              >
                Tidak siap
              </button>
            </div>
            <p className="mt-2 text-[11px] text-zinc-400">Check-in terakhir: {currentProfile.availabilityUpdatedAt ? `${formatWIB(currentProfile.availabilityUpdatedAt)} WIB` : "Belum ada"}. Saat login berikutnya, Anda diminta check-in lagi.</p>
          </div>
        )}

        {/* Keamanan & sesi */}
        <div className="glass-card p-4 sm:p-5">
          <div className="text-sm font-bold">Keamanan & sesi</div>
          <dl className="mt-2 space-y-1.5 text-sm">
            <div className="flex items-center justify-between gap-2">
              <dt className="text-zinc-500">Email login</dt>
              <dd className="truncate font-semibold">{userEmail ?? "-"}</dd>
            </div>
            <div className="flex items-center justify-between gap-2">
              <dt className="text-zinc-500">No. WhatsApp</dt>
              <dd className="truncate font-semibold">{currentProfile.whatsapp || "-"}</dd>
            </div>
            <div className="flex items-center justify-between gap-2">
              <dt className="text-zinc-500">ID akun</dt>
              <dd className="font-mono text-xs text-zinc-600">{currentProfile.id.slice(0, 8)}…</dd>
            </div>
            <div className="flex items-center justify-between gap-2">
              <dt className="text-zinc-500">Perangkat ini</dt>
              <dd className="font-semibold text-emerald-700">Sesi aktif</dd>
            </div>
          </dl>
          <div className="mt-3 flex flex-wrap gap-2">
            <button
              className="btn-ghost rounded-xl px-3.5 py-2 text-sm font-semibold"
              onClick={() => {
                void signOut().then(() => router.push("/login"));
              }}
            >
              Keluar dari perangkat ini
            </button>
            <a href="/lupa-password" className="rounded-xl px-3.5 py-2 text-sm font-semibold text-indigo-700 underline decoration-indigo-200 underline-offset-2 hover:text-indigo-900">
              Ganti kata sandi
            </a>
          </div>
        </div>

        {/* Akses peran */}
        <div className="glass-card p-4 sm:p-5">
          <div className="text-sm font-bold">Yang bisa dilakukan peran {ROLE_LABELS[currentProfile.role]}</div>
          <ul className="mt-2 space-y-1.5">
            {capabilities.map((c) => (
              <li key={c} className="flex items-start gap-2 text-sm">
                <span className="mt-0.5 inline-flex h-4.5 w-4.5 shrink-0 items-center justify-center rounded-full bg-emerald-100 text-[10px] font-bold text-emerald-800 ring-1 ring-inset ring-emerald-200" aria-hidden>✓</span>
                {c}
              </li>
            ))}
          </ul>
          <p className="mt-2 text-[11px] text-zinc-500">Pengguna tidak dapat mengubah role sendiri. Perubahan dicatat dan dikelola Super Admin.</p>
        </div>

        {/* Aktivitas terakhir */}
        <div className="glass-card p-4 sm:p-5">
          <div className="text-sm font-bold">Aktivitas terakhir saya</div>
          {myActivity.length === 0 && <p className="mt-2 text-xs text-zinc-500">Belum ada aktivitas tercatat.</p>}
          <ul className="relative mt-2 space-y-2 border-l-2 border-indigo-100 pl-4">
            {myActivity.map((e) => (
              <li key={e.id} className="relative text-xs text-zinc-600">
                <span className="absolute -left-[22px] top-1 h-2.5 w-2.5 rounded-full bg-gradient-to-br from-indigo-500 to-violet-500 ring-2 ring-white" aria-hidden />
                <span className="font-semibold text-zinc-800">{formatWIB(e.createdAt)}</span>
                <span className="ml-1.5 rounded-md bg-zinc-100 px-1.5 py-0.5 font-mono text-[11px]">{e.type}</span>
                <span className="ml-1.5 font-medium">{e.jobId}</span>
                {e.reason && <span className="block italic text-zinc-500">“{e.reason}”</span>}
              </li>
            ))}
          </ul>
        </div>
      </div>

      {currentProfile.role === "freelance" && <FreelancerBankAccountForm />}
    </div>
  );
}

export function PengaturanPanel({ onToast }: { onToast: Toast }) {
  const { data, currentProfile, realtime, refresh, updateSla, updateCapacity } = useReadyStore();
  const [sla, setSla] = useState(data.slaHours);
  const [cap, setCap] = useState(data.maxActive);
  const [browserNotif, setBrowserNotif] = useState(false);
  const [slaReason, setSlaReason] = useState("");
  const [capReason, setCapReason] = useState("");
  const [saving, setSaving] = useState<"sla" | "cap" | null>(null);
  const isAdmin = hasOperationsAccess(currentProfile.role);
  const slaDirty = sla !== data.slaHours;
  const capDirty = cap !== data.maxActive;

  const save = (which: "sla" | "cap") => {
    setSaving(which);
    const done = (r: { ok: boolean; error?: string }, okMsg: string) => {
      setSaving(null);
      onToast(r.ok ? okMsg : (r.error ?? "Gagal"));
      if (r.ok) {
        if (which === "sla") setSlaReason("");
        else setCapReason("");
      }
    };
    if (which === "sla") void updateSla(sla, slaReason).then((r) => done(r, `SLA ${sla} jam berlaku untuk semua perangkat`));
    else void updateCapacity(cap, capReason).then((r) => done(r, `Batas ${cap} job aktif tersimpan`));
  };

  const toggleNotif = () => {
    const next = !browserNotif;
    setBrowserNotif(next);
    if (next && typeof window !== "undefined" && "Notification" in window) void Notification.requestPermission();
    onToast(next ? "Notifikasi browser aktif (hanya saat aplikasi terbuka + izin)" : "Notifikasi browser dimatikan");
  };

  return (
    <div className="space-y-3">
      {/* Hero */}
      <div className="auth-side relative overflow-hidden rounded-3xl p-5 text-white sm:p-6">
        <div className="relative flex flex-wrap items-center gap-3">
          <div className="min-w-0 flex-1">
            <h2 className="text-xl font-extrabold tracking-tight sm:text-2xl">Pengaturan</h2>
            <p className="mt-0.5 text-sm text-white/75">Aturan main bersama yang berlaku untuk semua perangkat.</p>
          </div>
          <span className={`rounded-full px-3 py-1 text-[11px] font-bold uppercase tracking-widest ring-1 ring-inset ${isAdmin ? "bg-emerald-300/20 text-emerald-100 ring-emerald-200/40" : "bg-white/10 text-white/75 ring-white/25"}`}>
            {isAdmin ? `Mode ubah (${ROLE_LABELS[currentProfile.role]})` : `Mode baca (${ROLE_LABELS[currentProfile.role]})`}
          </span>
        </div>
        {!isAdmin && (
          <p className="relative mt-3 rounded-xl bg-white/10 px-3 py-2 text-xs text-white/85 ring-1 ring-inset ring-white/20">
            Anda masuk sebagai Freelance — nilai di bawah hanya bisa dibaca. Perubahan dilakukan Admin.
          </p>
        )}
      </div>

      <div className="grid gap-3 lg:grid-cols-5">
        {/* Aturan kerja */}
        <div className="glass-card p-4 sm:p-5 lg:col-span-3">
          <div className="text-sm font-bold">Aturan kerja bersama</div>

          <div className="mt-3 rounded-2xl bg-white/60 p-3 ring-1 ring-inset ring-zinc-200/80">
            <div className="flex items-center justify-between gap-2">
              <label htmlFor="set-sla" className="text-sm font-bold">SLA urgensi</label>
              <span className="rounded-lg bg-indigo-50 px-2 py-0.5 text-sm font-extrabold tabular-nums text-indigo-900 ring-1 ring-inset ring-indigo-200">{sla} jam</span>
            </div>
            <div className="mt-2 flex items-center gap-3">
              <input
                id="set-sla" type="range" min={1} max={72} step={1} value={sla}
                disabled={!isAdmin} onChange={(e) => setSla(Number(e.target.value))}
                className="h-2 flex-1 cursor-pointer appearance-none rounded-full bg-gradient-to-r from-indigo-200 via-violet-200 to-amber-200 accent-indigo-600 disabled:cursor-not-allowed disabled:opacity-60"
              />
              <input
                type="number" min={1} max={72} value={sla} disabled={!isAdmin}
                onChange={(e) => setSla(Number(e.target.value))}
                className="input w-20 px-2 py-1 text-center text-sm font-bold tabular-nums"
              />
            </div>
            <p className="mt-1.5 text-xs text-zinc-500">Job <b>Antre</b> menjadi <b>Urgen</b> setelah menunggu ≥ {sla} jam sejak ditugaskan.</p>
            <input className="input mt-2 w-full px-3 py-2 text-xs" value={slaReason} disabled={!isAdmin} onChange={(e) => setSlaReason(e.target.value)} placeholder="Alasan perubahan untuk audit" aria-label="Alasan perubahan SLA" />
            <button
              className="btn-primary mt-2 rounded-xl px-4 py-1.5 text-sm font-semibold text-white disabled:opacity-40"
              disabled={!isAdmin || !slaDirty || !slaReason.trim() || saving !== null}
              onClick={() => save("sla")}
            >
              {saving === "sla" ? "Menyimpan…" : slaDirty ? "Simpan SLA" : "Sudah tersimpan"}
            </button>
          </div>

          <div className="mt-3 rounded-2xl bg-white/60 p-3 ring-1 ring-inset ring-zinc-200/80">
            <div className="flex items-center justify-between gap-2">
              <label htmlFor="set-cap" className="text-sm font-bold">Batas job aktif <span className="font-medium text-zinc-400">(D-26)</span></label>
              <span className="rounded-lg bg-indigo-50 px-2 py-0.5 text-sm font-extrabold tabular-nums text-indigo-900 ring-1 ring-inset ring-indigo-200">{cap} job</span>
            </div>
            <div className="mt-2 flex items-center gap-3">
              <input
                id="set-cap" type="range" min={1} max={20} step={1} value={cap}
                disabled={!isAdmin} onChange={(e) => setCap(Number(e.target.value))}
                className="h-2 flex-1 cursor-pointer appearance-none rounded-full bg-gradient-to-r from-indigo-200 via-violet-200 to-amber-200 accent-indigo-600 disabled:cursor-not-allowed disabled:opacity-60"
              />
              <input
                type="number" min={1} max={20} value={cap} disabled={!isAdmin}
                onChange={(e) => setCap(Number(e.target.value))}
                className="input w-20 px-2 py-1 text-center text-sm font-bold tabular-nums"
              />
            </div>
            <p className="mt-1.5 text-xs text-zinc-500">Freelance <b>penuh</b> saat memiliki ≥ {cap} job aktif (Antre/Dikerjakan/Preview/ACC). Dicek atomik di backend.</p>
            <input className="input mt-2 w-full px-3 py-2 text-xs" value={capReason} disabled={!isAdmin} onChange={(e) => setCapReason(e.target.value)} placeholder="Alasan perubahan untuk audit" aria-label="Alasan perubahan batas job" />
            <button
              className="btn-primary mt-2 rounded-xl px-4 py-1.5 text-sm font-semibold text-white disabled:opacity-40"
              disabled={!isAdmin || !capDirty || !capReason.trim() || saving !== null}
              onClick={() => save("cap")}
            >
              {saving === "cap" ? "Menyimpan…" : capDirty ? "Simpan batas" : "Sudah tersimpan"}
            </button>
          </div>
        </div>

        <div className="space-y-3 lg:col-span-2">
          {/* Koneksi */}
          <div className="glass-card p-4 sm:p-5">
            <div className="text-sm font-bold">Koneksi & notifikasi</div>
            <div className={`mt-2 flex items-center gap-2 rounded-xl px-3 py-2 text-sm font-semibold ring-1 ring-inset ${
              realtime === "on" ? "bg-emerald-50 text-emerald-900 ring-emerald-200"
              : realtime === "connecting" ? "bg-zinc-100 text-zinc-600 ring-zinc-200"
              : "bg-amber-50 text-amber-900 ring-amber-200"
            }`}>
              <span className={`h-2 w-2 rounded-full ${realtime === "on" ? "bg-emerald-500" : realtime === "connecting" ? "bg-zinc-400" : "bg-amber-500"}`} />
              {realtime === "on" ? "Realtime terhubung" : realtime === "connecting" ? "Menghubungkan…" : "Realtime terputus"}
              <button className="ml-auto text-xs font-bold underline underline-offset-2" onClick={() => { refresh(); onToast("Memuat ulang dari server…"); }}>
                Muat ulang
              </button>
            </div>
            <div className="mt-3 flex items-center justify-between gap-3">
              <div>
                <div className="text-sm font-bold">Notifikasi browser</div>
                <div className="text-[11px] text-zinc-500">Opsional, hanya saat aplikasi terbuka + izin.</div>
              </div>
              <button
                role="switch" aria-checked={browserNotif} aria-label="Notifikasi browser"
                onClick={toggleNotif}
                className={`relative h-6 w-11 shrink-0 rounded-full transition-colors ${browserNotif ? "bg-gradient-to-r from-indigo-600 to-violet-600" : "bg-zinc-300"}`}
              >
                <span className={`absolute top-0.5 h-5 w-5 rounded-full bg-white shadow transition-all ${browserNotif ? "left-[22px]" : "left-0.5"}`} />
              </button>
            </div>
          </div>

          {/* Ketentuan sistem */}
          <div className="glass-card-gradient relative overflow-hidden p-4 sm:p-5">
            <div className="pointer-events-none absolute -right-10 -top-12 h-32 w-32 rounded-full bg-violet-300/20 blur-2xl" />
            <div className="relative">
              <div className="flex items-start gap-3">
                <span className="grid size-9 shrink-0 place-items-center rounded-xl bg-gradient-to-br from-indigo-600 to-violet-600 text-white shadow-md shadow-indigo-900/15" aria-hidden="true">
                  <svg viewBox="0 0 24 24" fill="none" className="size-4" stroke="currentColor" strokeWidth="1.8">
                    <path strokeLinecap="round" strokeLinejoin="round" d="M12 3.75 19.5 7.5v4.75c0 4.15-2.85 7.45-7.5 8.75-4.65-1.3-7.5-4.6-7.5-8.75V7.5L12 3.75Z" />
                    <path strokeLinecap="round" strokeLinejoin="round" d="m9 12 2 2 4-4" />
                  </svg>
                </span>
                <div className="min-w-0 flex-1">
                  <h3 className="text-sm font-extrabold tracking-tight text-zinc-900">Ketentuan sistem</h3>
                  <p className="mt-0.5 text-xs text-zinc-600">Standar file dan aturan operasional</p>
                </div>
                <span className="shrink-0 rounded-full bg-white/75 px-2.5 py-1 text-[10px] font-bold uppercase tracking-wide text-indigo-700 ring-1 ring-inset ring-indigo-100">Berlaku bersama</span>
              </div>

              <section aria-labelledby="system-file-rules" className="mt-4 rounded-2xl border border-white/80 bg-white/65 p-3 shadow-sm shadow-indigo-950/5">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <h4 id="system-file-rules" className="text-xs font-extrabold text-zinc-800">File dan penyimpanan</h4>
                  <span className="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">Format didukung</span>
                </div>
                <ul aria-label="Format file yang didukung" className="mt-2 flex flex-wrap gap-1.5">
                  {["PDF", "Gambar", "Dokumen", "AI", "PSD", "CDR"].map((format) => (
                    <li key={format} className="rounded-lg bg-indigo-50/90 px-2 py-1 text-[11px] font-bold text-indigo-800 ring-1 ring-inset ring-indigo-100">{format}</li>
                  ))}
                </ul>
                <div className="mt-3 grid grid-cols-3 gap-2">
                  {[
                    ["1 GiB", "per file"],
                    ["10 GiB", "per job"],
                    ["30 hari", "retensi"],
                  ].map(([value, label]) => (
                    <div key={label} className="rounded-xl bg-white/80 px-2 py-2 text-center ring-1 ring-inset ring-zinc-200/80">
                      <div className="text-xs font-extrabold tabular-nums text-zinc-900">{value}</div>
                      <div className="mt-0.5 text-[10px] text-zinc-500">{label}</div>
                    </div>
                  ))}
                </div>
              </section>

              <section aria-labelledby="system-operation-rules" className="mt-4">
                <div className="flex items-center justify-between gap-2">
                  <h4 id="system-operation-rules" className="text-xs font-extrabold text-zinc-800">Aturan operasional</h4>
                  <span className="text-[10px] text-zinc-500">5 ketentuan</span>
                </div>
                <ul className="mt-2 grid grid-cols-2 gap-2">
                  {[
                    ["Presence", "Heartbeat < 90 detik", "Realtime"],
                    ["Zona waktu", "Asia/Jakarta", "D-25"],
                    ["Fee", "Rupiah bulat, dikunci saat ACC", "D-22"],
                    ["Review", "Target 1×24 jam, tanpa pengingat otomatis", "D-23"],
                    ["Koreksi ACC", "Buat job lanjutan baru", "D-24"],
                  ].map(([label, value, reference]) => (
                    <li key={label} className="min-w-0 rounded-xl border border-white/80 bg-white/65 p-2.5 shadow-sm shadow-indigo-950/5">
                      <div className="flex items-center justify-between gap-1.5">
                        <span className="text-[11px] font-bold text-zinc-700">{label}</span>
                        <span className="shrink-0 rounded-md bg-zinc-100 px-1.5 py-0.5 text-[9px] font-bold text-zinc-500">{reference}</span>
                      </div>
                      <p className="mt-1 text-[11px] leading-relaxed text-zinc-600">{value}</p>
                    </li>
                  ))}
                </ul>
              </section>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
