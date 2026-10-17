"use client";

import { useEffect, useMemo, useState, type ReactNode } from "react";
import { usePathname, useRouter } from "next/navigation";
import { useStore } from "@/lib/store-context";
import { hasOperationsAccess, isTerlambat, isUrgen, type Profile } from "@/lib/domain";
import { useNow } from "./threadline-ui";
import { AppShell, type NavTab } from "./app-shell";

const PATH_TAB: Record<string, NavTab> = {
  dashboard: "dashboard",
  intake: "intake",
  arsip: "arsip",
  chat: "chat",
  rekap: "rekap",
  pendaftaran: "pendaftaran",
  pengguna: "pengguna",
  akun: "akun",
  pengaturan: "pengaturan",
};
type AvailabilityChoice = Exclude<Profile["availabilityStatus"], "pending">;

function FreelancerCheckIn({
  onChoose,
  onSignOut,
  saving,
  error,
}: {
  onChoose: (status: AvailabilityChoice) => void;
  onSignOut: () => void;
  saving: boolean;
  error: string;
}) {
  return (
    <main className="flex min-h-screen items-center justify-center bg-zinc-50 p-5 sm:p-8">
      <section className="glass-card-gradient w-full max-w-2xl overflow-hidden">
        <div className="border-b border-indigo-100/80 px-6 py-5 sm:px-8">
          <p className="text-xs font-bold uppercase tracking-[0.18em] text-indigo-600">Threadline · Check-in freelancer</p>
          <h1 className="mt-2 text-2xl font-extrabold tracking-tight text-zinc-900">Bagaimana kesiapan Anda saat ini?</h1>
          <p className="mt-1 text-sm leading-6 text-zinc-600">Pilih status saat masuk. Admin dapat melihat status online dan kesiapan Anda secara realtime.</p>
        </div>
        <div className="space-y-3 p-5 sm:p-8">
          <button
            type="button"
            disabled={saving}
            onClick={() => onChoose("ready")}
            className="group flex w-full items-center gap-4 rounded-2xl border border-emerald-200 bg-gradient-to-r from-emerald-50 to-teal-50 p-4 text-left transition hover:border-emerald-300 hover:shadow-md disabled:opacity-60 sm:p-5"
          >
            <span className="grid size-11 shrink-0 place-items-center rounded-2xl bg-emerald-600 text-white shadow-sm" aria-hidden>
              <svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"><path d="m5 12 4 4L19 6" /></svg>
            </span>
            <span className="min-w-0 flex-1">
              <span className="block text-base font-extrabold text-emerald-950">Siap menerima job</span>
              <span className="mt-0.5 block text-sm text-emerald-800/80">Admin akan tahu Anda bisa dipertimbangkan untuk penugasan.</span>
            </span>
            <span className="text-lg font-bold text-emerald-700 transition-transform group-hover:translate-x-1" aria-hidden>→</span>
          </button>
          <button
            type="button"
            disabled={saving}
            onClick={() => onChoose("unavailable")}
            className="group flex w-full items-center gap-4 rounded-2xl border border-zinc-200 bg-white/80 p-4 text-left transition hover:border-zinc-300 hover:bg-white hover:shadow-md disabled:opacity-60 sm:p-5"
          >
            <span className="grid size-11 shrink-0 place-items-center rounded-2xl bg-zinc-100 text-zinc-600 ring-1 ring-inset ring-zinc-200" aria-hidden>
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M6 6l12 12M18 6 6 18" /></svg>
            </span>
            <span className="min-w-0 flex-1">
              <span className="block text-base font-extrabold text-zinc-900">Tidak siap menerima job</span>
              <span className="mt-0.5 block text-sm text-zinc-500">Anda tetap bisa membuka aplikasi; Admin akan melihat bahwa Anda sedang tidak tersedia.</span>
            </span>
            <span className="text-lg font-bold text-zinc-400 transition-transform group-hover:translate-x-1" aria-hidden>→</span>
          </button>
          {saving && <p className="text-center text-sm text-zinc-500">Menyimpan check-in…</p>}
          {error && <p role="alert" className="rounded-xl bg-rose-50 px-3.5 py-2.5 text-sm text-rose-800 ring-1 ring-inset ring-rose-200">{error}</p>}
          <div className="flex flex-wrap items-center justify-between gap-3 border-t border-indigo-100/80 pt-4">
            <p className="text-xs text-zinc-500">Pilihan ini bisa diubah kapan saja dari halaman Akun.</p>
            <button type="button" disabled={saving} onClick={onSignOut} className="btn-ghost rounded-xl px-3.5 py-2 text-sm font-semibold">Keluar</button>
          </div>
        </div>
      </section>
    </main>
  );
}

export function AppFrame({ children }: { children: ReactNode }) {
  const { data, currentProfile, userEmail, signOut, realtime, authReady, userId, beginFreelancerCheckIn, setFreelancerAvailability } = useStore();
  const pathname = usePathname();
  const router = useRouter();
  const now = useNow();
  const [checkInResolved, setCheckInResolved] = useState(false);
  const [showCheckIn, setShowCheckIn] = useState(false);
  const [checkInSaving, setCheckInSaving] = useState(false);
  const [checkInError, setCheckInError] = useState("");

  const tab: NavTab = PATH_TAB[pathname.split("/")[1] ?? ""] ?? "dashboard";
  const financeRouteAllowed = currentProfile?.role !== "finance" || tab === "rekap" || tab === "akun";
  const superAdminRouteAllowed = currentProfile?.role === "super_admin" || tab !== "pengguna";
  const registrationReviewRouteAllowed = (currentProfile !== null && hasOperationsAccess(currentProfile.role)) || tab !== "pendaftaran";

  useEffect(() => {
    if (authReady && !userId) router.push("/login");
  }, [authReady, userId, router]);

  useEffect(() => {
    if (!authReady) return;
    if (currentProfile?.role !== "freelance" || !currentProfile.isActive || currentProfile.registrationStatus !== "approved") {
      setCheckInResolved(true);
      setShowCheckIn(false);
      return;
    }
    const key = `threadline:freelancer-checkin:${currentProfile.id}`;
    const state = window.sessionStorage.getItem(key);
    setCheckInResolved(true);
    if (state === "done") {
      setShowCheckIn(false);
      return;
    }
    setShowCheckIn(true);
    if (state === "pending") return;
    window.sessionStorage.setItem(key, "pending");
    setCheckInSaving(true);
    void beginFreelancerCheckIn()
      .then((result) => {
        if (!result.ok) setCheckInError(result.error ?? "Status kesiapan belum dapat disimpan.");
      })
      .catch(() => setCheckInError("Koneksi terputus. Coba pilih status lagi."))
      .finally(() => setCheckInSaving(false));
  }, [authReady, currentProfile?.id, currentProfile?.role, currentProfile?.isActive, currentProfile?.registrationStatus, beginFreelancerCheckIn]);

  useEffect(() => {
    if (authReady && currentProfile?.role === "finance" && !financeRouteAllowed) {
      router.replace("/rekap");
    }
  }, [authReady, currentProfile?.role, financeRouteAllowed, router]);

  useEffect(() => {
    if (authReady && currentProfile && !superAdminRouteAllowed) router.replace("/dashboard");
  }, [authReady, currentProfile, superAdminRouteAllowed, router]);

  useEffect(() => {
    if (authReady && currentProfile && !registrationReviewRouteAllowed) router.replace("/dashboard");
  }, [authReady, currentProfile, registrationReviewRouteAllowed, router]);

  const visibleJobs = useMemo(() => {
    if (!currentProfile) return [];
    if (hasOperationsAccess(currentProfile.role)) return data.jobs;
    if (currentProfile.role === "finance") return data.jobs.filter((job) => job.status === "Finished");
    return data.jobs.filter((j) => j.assigneeId === currentProfile.id);
  }, [data.jobs, currentProfile]);

  const counts = {
    intake: (currentProfile && hasOperationsAccess(currentProfile.role) ? data.jobs : visibleJobs).filter((j) => j.status === "Belum Ditugaskan").length,
    arsip: visibleJobs.filter((j) => j.status === "Finished" || j.status === "Dibatalkan").length,
    express: visibleJobs.filter((j) => j.priority === "express" && !["Finished", "Dibatalkan"].includes(j.status)).length,
    urgen: visibleJobs.filter((j) => isUrgen(j, data.slaHours, now)).length,
    terlambat: visibleJobs.filter((j) => isTerlambat(j, now)).length,
    registrations: data.pendingFreelancerRegistrations.length,
  };

  if (!authReady) {
    return <div className="p-8 text-sm text-zinc-500">Memuat sesi & profil…</div>;
  }

  if (!userId) return <div className="p-8 text-sm text-zinc-500">Mengarahkan ke halaman login…</div>;

  if (!currentProfile) {
    return <div className="p-8 text-sm text-zinc-600">Profil akun belum tersedia. Hubungi Super Admin.</div>;
  }

  const registrationPending = !currentProfile.isActive && currentProfile.registrationStatus === "pending";

  if (!currentProfile.isActive && !registrationPending) {
    const rejected = currentProfile.registrationStatus === "rejected";
    return (
      <main className="flex min-h-screen items-center justify-center bg-zinc-50 p-6">
        <section className="glass-card max-w-md p-6 text-center">
          <h1 className="text-lg font-extrabold">{rejected ? "Pendaftaran belum disetujui" : "Akses akun dinonaktifkan"}</h1>
          <p className="mt-2 text-sm text-zinc-600">
            {rejected
              ? "Admin atau Super Admin belum menyetujui pendaftaran ini. Hubungi tim Threadline jika Anda ingin menanyakan keputusan."
              : "Akun ini tidak dapat menggunakan Threadline. Hubungi Super Admin bila Anda memerlukan akses kembali."}
          </p>
          {rejected && currentProfile.registrationReviewReason && (
            <p className="mt-3 rounded-xl border border-rose-200 bg-rose-50 p-3 text-left text-sm text-rose-900">
              <span className="block text-xs font-bold uppercase tracking-wide text-rose-700">Catatan admin</span>
              <span className="mt-1 block">{currentProfile.registrationReviewReason}</span>
            </p>
          )}
          <button className="btn-primary mt-4 rounded-xl px-4 py-2 text-sm font-semibold text-white" onClick={() => { void signOut().then(() => router.replace("/login")); }}>
            Keluar
          </button>
        </section>
      </main>
    );
  }

  if (!registrationPending && currentProfile.role === "freelance" && !checkInResolved) {
    return <div className="flex min-h-screen items-center justify-center text-sm text-zinc-500">Memuat check-in kesiapan…</div>;
  }

  if (!registrationPending && currentProfile.role === "freelance" && showCheckIn) {
    const chooseAvailability = async (status: AvailabilityChoice) => {
      setCheckInSaving(true);
      setCheckInError("");
      try {
        const result = await setFreelancerAvailability(status);
        if (!result.ok) {
          setCheckInError(result.error ?? "Status kesiapan belum dapat disimpan.");
          return;
        }
        window.sessionStorage.setItem(`threadline:freelancer-checkin:${currentProfile.id}`, "done");
        setShowCheckIn(false);
      } catch {
        setCheckInError("Koneksi terputus. Coba pilih status lagi.");
      } finally {
        setCheckInSaving(false);
      }
    };
    return (
      <FreelancerCheckIn
        onChoose={(status) => { void chooseAvailability(status); }}
        onSignOut={() => { void signOut().then(() => router.replace("/login")); }}
        saving={checkInSaving}
        error={checkInError}
      />
    );
  }

  if (!financeRouteAllowed) return <div className="p-8 text-sm text-zinc-500">Mengarahkan ke Rekap & Pembayaran…</div>;
  if (!superAdminRouteAllowed || !registrationReviewRouteAllowed) return <div className="p-8 text-sm text-zinc-500">Mengarahkan ke Dashboard…</div>;

  const app = (
    <AppShell
      tab={tab}
      setTab={(t) => router.push(`/${t}`)}
      counts={counts}
      userName={currentProfile.name}
      userRole={currentProfile.role}
      userEmail={userEmail}
      userPhotoUrl={data.profilePhotoUrl}
      realtime={realtime}
      lockedOverlay={registrationPending ? (
        <section className="w-full max-w-md overflow-hidden rounded-3xl border border-red-200 bg-white/95 shadow-2xl shadow-red-950/20">
          <div className="bg-gradient-to-r from-red-600 via-rose-950 to-zinc-950 px-6 py-5 text-white sm:px-7">
            <span className="inline-flex items-center gap-2 rounded-full border border-white/25 bg-white/15 px-3 py-1 text-[11px] font-extrabold uppercase tracking-[0.16em]">
              <span className="size-2 rounded-full bg-rose-200" />
              Admin Review
            </span>
            <h2 id="locked-overlay-title" className="mt-3 text-xl font-extrabold tracking-tight">Akun sedang menunggu review Admin</h2>
          </div>
          <div className="space-y-4 p-6 sm:p-7">
            <p className="text-sm leading-6 text-zinc-600">Anda berhasil masuk ke dashboard, tetapi semua fitur masih terkunci sampai Admin menyetujui pendaftaran akun ini.</p>
            <div className="flex items-center justify-between gap-3 border-t border-zinc-100 pt-4">
              <span className="text-xs font-semibold text-rose-800">Status: Menunggu review</span>
              <button type="button" onClick={() => { void signOut().then(() => router.replace("/login")); }} className="btn-ghost rounded-xl px-3.5 py-2 text-sm font-semibold">Keluar</button>
            </div>
          </div>
        </section>
      ) : undefined}
      onSignOut={() => {
        void signOut().then(() => router.push("/login"));
      }}
    >
      {realtime === "off" && (
        <div className={`chip-notif mb-4 rounded-2xl px-4 py-2.5 text-sm font-medium ${tab === "dashboard" ? "xl:shrink-0" : ""}`}>
          Realtime terputus. Data mungkin basi — muat ulang halaman untuk sinkronisasi.
        </div>
      )}
      {children}
      {tab !== "dashboard" && <footer className="px-1 pb-6 pt-6 text-xs text-zinc-500">
        Data real dari Supabase (Auth + RLS + Realtime + Storage). Keputusan terbuka: pengingat Belum Ditugaskan.
      </footer>}
    </AppShell>
  );

  return app;
}
