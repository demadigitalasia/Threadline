"use client";

import Image from "next/image";
import { useEffect, useState, type ReactNode } from "react";
import { ROLE_LABELS, type Role } from "@/lib/domain";
import { ThreadlineLogo } from "@/components/threadline-logo";

export type NavTab = "dashboard" | "intake" | "arsip" | "chat" | "rekap" | "pendaftaran" | "pengguna" | "akun" | "pengaturan";

export const TAB_META: Record<NavTab, { label: string; desc: string }> = {
  dashboard: { label: "Dashboard", desc: "Ringkasan beban kerja dan semua job yang terlihat." },
  intake: { label: "Antrean Intake", desc: "Job Belum Ditugaskan menunggu penerima." },
  arsip: { label: "Arsip & Batal", desc: "Job Finished yang selesai dan yang dibatalkan." },
  chat: { label: "Chat", desc: "Thread langsung per Freelance dengan Admin dan Super Admin." },
  rekap: { label: "Rekap & Pembayaran", desc: "Rekap fee, transfer aktual, dan saldo kewajiban freelancer." },
  pendaftaran: { label: "Pendaftaran Freelancer", desc: "Tinjau dan putuskan permohonan akun freelancer." },
  pengguna: { label: "Manajemen Pengguna", desc: "Akun pengguna, pengaturan akses, dan riwayat perubahan." },
  akun: { label: "Akun", desc: "Profil kerja dan sesi perangkat ini." },
  pengaturan: { label: "Pengaturan", desc: "SLA urgensi bersama dan koneksi." },
};

function I({ children }: { children: ReactNode }) {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      {children}
    </svg>
  );
}

const ICONS: Record<NavTab, ReactNode> = {
  dashboard: <I><rect x="3" y="3" width="7.5" height="7.5" rx="1.8" /><rect x="13.5" y="3" width="7.5" height="7.5" rx="1.8" /><rect x="3" y="13.5" width="7.5" height="7.5" rx="1.8" /><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="1.8" /></I>,
  intake: <I><path d="M3 13h5l2 3h4l2-3h5" /><path d="M5.5 5h13l2 8v5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2V13l2-8z" /></I>,
  arsip: <I><rect x="3" y="4" width="18" height="5" rx="1" /><path d="M5 9v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9" /><path d="M10 13.5h4" /></I>,
  chat: <I><path d="M21 11.5a8.5 8.5 0 0 1-8.5 8.5c-1.5 0-3-.4-4.2-1L3 20l1.1-4.3A8.5 8.5 0 1 1 21 11.5z" /></I>,
  rekap: <I><path d="M20 7H4a2 2 0 0 1 0-4h14v4" /><path d="M20 7a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5" /><circle cx="17" cy="14" r="1.3" /></I>,
  pendaftaran: <I><circle cx="9" cy="8" r="3.5" /><path d="M2.5 20c0-3.5 2.8-5.5 6.5-5.5s6.5 2 6.5 5.5" /><path d="m17 11 2 2 3-3" /></I>,
  pengguna: <I><circle cx="9" cy="8" r="3.5" /><path d="M2.5 20c0-3.5 2.8-5.5 6.5-5.5 1.2 0 2.3.2 3.2.7" /><path d="M16.5 12.5a3 3 0 1 0 0-6" /><path d="M15 16c3.5 0 6 1.5 6 4" /></I>,
  akun: <I><circle cx="12" cy="8" r="4" /><path d="M4 21c0-4 3.6-6.5 8-6.5s8 2.5 8 6.5" /></I>,
  pengaturan: <I><circle cx="12" cy="12" r="3" /><path d="M19 12a7 7 0 0 0-.1-1.2l2-1.6-2-3.4-2.4 1a7 7 0 0 0-2-1.2L14 3h-4l-.5 2.6a7 7 0 0 0-2 1.2l-2.4-1-2 3.4 2 1.6A7 7 0 0 0 5 12c0 .4 0 .8.1 1.2l-2 1.6 2 3.4 2.4-1a7 7 0 0 0 2 1.2L10 21h4l.5-2.6a7 7 0 0 0 2-1.2l2.4 1 2-3.4-2-1.6c.06-.4.1-.8.1-1.2z" /></I>,
};

export function TabIcon({ tab }: { tab: NavTab }) {
  return <>{ICONS[tab]}</>;
}

export interface NavCounts {
  intake: number;
  arsip: number;
  express: number;
  urgen: number;
  terlambat: number;
  registrations: number;
}

const MENU_MAIN: NavTab[] = ["dashboard", "intake", "arsip", "chat", "rekap"];
const MENU_SYS: NavTab[] = ["akun", "pengaturan"];

function badgeFor(tab: NavTab, c: NavCounts): number {
  if (tab === "pendaftaran") return c.registrations;
  if (tab === "intake") return c.intake;
  if (tab === "arsip") return c.arsip;
  if (tab === "dashboard") return c.urgen + c.terlambat;
  return 0;
}

function NavList({ tab, setTab, counts, role, onNav, compact = false }: {
  tab: NavTab; setTab: (t: NavTab) => void; counts: NavCounts; role: Role; onNav?: () => void; compact?: boolean;
}) {
  const menuMain = role === "finance" ? ["rekap"] as NavTab[] : MENU_MAIN;
  const menuSystem = role === "finance"
    ? ["akun"] as NavTab[]
    : role === "super_admin"
      ? ["pendaftaran", "pengguna", "akun", "pengaturan"] as NavTab[]
      : role === "admin"
        ? ["pendaftaran", ...MENU_SYS] as NavTab[]
        : MENU_SYS;
  const render = (id: NavTab) => {
    const active = tab === id;
    const badge = badgeFor(id, counts);
    return (
      <button
        key={id}
        onClick={() => { setTab(id); onNav?.(); }}
        aria-current={active ? "page" : undefined}
        aria-label={compact ? TAB_META[id].label : undefined}
        title={compact ? TAB_META[id].label : undefined}
        className={`group relative flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium transition-all ${
          active ? "bg-white/15 text-white shadow-[0_8px_20px_-8px_rgba(0,0,0,0.5)]" : "text-white/65 hover:bg-white/10 hover:text-white"
        } ${compact ? "justify-center px-2 xl:justify-start xl:px-3" : ""}`}
      >
        {active && <span className="absolute inset-y-2 left-0 w-1 rounded-full bg-gradient-to-b from-amber-300 to-rose-400" aria-hidden />}
        <span className={active ? "text-amber-200" : "text-white/55 group-hover:text-white/90"}>{ICONS[id]}</span>
        <span className={`flex-1 text-left ${compact ? "sr-only xl:not-sr-only" : ""}`}>{TAB_META[id].label}</span>
        {badge > 0 && (
          <span className={`rounded-full px-2 py-0.5 text-[11px] font-bold tabular-nums ${active ? "bg-amber-300 text-indigo-950" : "bg-white/15 text-white"} ${compact ? "absolute right-1 top-1 px-1 text-[9px] xl:static xl:px-2 xl:text-[11px]" : ""}`}>
            {badge}
          </span>
        )}
      </button>
    );
  };
  return (
    <nav className={compact ? "space-y-4" : "space-y-5"}>
      <div>
        <p className={`${compact ? "hidden xl:block " : ""}mb-1.5 px-3 text-[10px] font-bold uppercase tracking-[0.18em] text-white/40`}>Menu utama</p>
        <div className="space-y-1">{menuMain.map(render)}</div>
      </div>
      <div>
        <p className={`${compact ? "hidden xl:block " : ""}mb-1.5 px-3 text-[10px] font-bold uppercase tracking-[0.18em] text-white/40`}>Sistem</p>
        <div className="space-y-1">{menuSystem.map(render)}</div>
      </div>
    </nav>
  );
}

export function AppShell({ tab, setTab, counts, userName, userRole, userEmail, userPhotoUrl, realtime, onSignOut, lockedOverlay, children }: {
  tab: NavTab;
  setTab: (t: NavTab) => void;
  counts: NavCounts;
  userName: string;
  userRole: Role;
  userEmail: string | null;
  userPhotoUrl: string | null;
  realtime: "connecting" | "on" | "off";
  onSignOut: () => void;
  lockedOverlay?: ReactNode;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const initial = (userName.trim()[0] ?? "?").toUpperCase();

  // Drawer mobile: Escape menutup + kunci scroll body saat terbuka.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("keydown", onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = prev;
    };
  }, [open]);

  return (
    <div className={`min-h-screen text-zinc-900 lg:flex ${tab === "dashboard" ? "xl:h-dvh xl:min-h-0 xl:overflow-hidden" : ""}`}>
      {/* Sidebar desktop */}
      <aside className="sidebar-dark sticky top-0 hidden h-screen w-20 shrink-0 flex-col p-2 lg:flex xl:w-64 xl:p-4">
        <div className="mb-5 flex min-h-11 items-center justify-center xl:justify-start xl:px-1">
          <ThreadlineLogo surface="transparent" compact className="xl:hidden" />
          <ThreadlineLogo surface="transparent" size="small" className="hidden w-36 xl:inline-flex" />
        </div>
        <div className="flex-1 overflow-y-auto">
          <NavList tab={tab} setTab={setTab} counts={counts} role={userRole} compact />
        </div>
        <div className="mt-4 hidden rounded-2xl border border-white/12 bg-white/8 p-3 xl:block">
          <div className="flex items-center gap-2.5">
            <span className="flex h-9 w-9 shrink-0 items-center justify-center overflow-hidden rounded-full bg-gradient-to-br from-amber-300 to-rose-400 text-sm font-extrabold text-indigo-950" aria-hidden>
              {userPhotoUrl ? <Image src={userPhotoUrl} alt="" width={36} height={36} unoptimized className="h-full w-full object-cover" /> : initial}
            </span>
            <div className="min-w-0 flex-1">
              <div className="truncate text-sm font-bold text-white">{userName}</div>
              <div className="truncate text-[11px] text-white/60">{ROLE_LABELS[userRole]} • {userEmail ?? "-"}</div>
            </div>
          </div>
          <div className="mt-2 flex items-center justify-between gap-2">
            <span className="text-[11px] text-white/60">
              {realtime === "on" ? "● realtime" : realtime === "connecting" ? "… menghubungkan" : "○ terputus"}
            </span>
            <button onClick={onSignOut} className="rounded-lg border border-white/20 px-2.5 py-1 text-xs font-semibold text-white/85 hover:bg-white/10">
              Keluar
            </button>
          </div>
        </div>
        <div className="mt-4 flex flex-col items-center gap-3 xl:hidden">
          <span title={`${userName} • ${ROLE_LABELS[userRole]}`} className="flex h-9 w-9 items-center justify-center overflow-hidden rounded-full bg-gradient-to-br from-amber-300 to-rose-400 text-sm font-extrabold text-indigo-950">
            {userPhotoUrl ? <Image src={userPhotoUrl} alt="" width={36} height={36} unoptimized className="h-full w-full object-cover" /> : initial}
          </span>
          <span
            title={realtime === "on" ? "Realtime aktif" : realtime === "connecting" ? "Menghubungkan realtime" : "Realtime terputus"}
            className={`h-2 w-2 rounded-full ${realtime === "on" ? "bg-emerald-400" : realtime === "connecting" ? "bg-zinc-300" : "bg-amber-300"}`}
          />
          <button onClick={onSignOut} aria-label="Keluar" title="Keluar" className="rounded-lg border border-white/20 p-2 text-white/85 hover:bg-white/10">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
              <path d="M10 17l5-5-5-5" /><path d="M15 12H3" /><path d="M12 3h6a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-6" />
            </svg>
          </button>
        </div>
      </aside>

      {/* Drawer mobile */}
      {open && (
        <div className="fixed inset-0 z-40 lg:hidden" role="dialog" aria-modal="true" aria-label="Menu navigasi">
          <div className="drawer-backdrop absolute inset-0 bg-zinc-950/50 backdrop-blur-[2px]" onClick={() => setOpen(false)} />
          <div className="sidebar-dark drawer-panel absolute inset-y-0 left-0 flex w-72 max-w-[85vw] flex-col p-4 shadow-2xl">
            <div className="flex items-center justify-between pb-4">
              <ThreadlineLogo surface="transparent" size="small" className="w-36 shrink-0" />
              <button onClick={() => setOpen(false)} aria-label="Tutup menu" className="rounded-lg p-2 text-white/70 hover:bg-white/10 hover:text-white">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" aria-hidden><path d="M18 6 6 18M6 6l12 12" /></svg>
              </button>
            </div>
            <div className="flex-1 overflow-y-auto">
              <NavList tab={tab} setTab={setTab} counts={counts} role={userRole} onNav={() => setOpen(false)} />
            </div>
            <button onClick={onSignOut} className="mt-3 rounded-xl border border-white/20 px-3 py-2 text-sm font-semibold text-white/90 hover:bg-white/10">
              Keluar ({userName})
            </button>
          </div>
        </div>
      )}

      {/* Kolom konten full-width */}
      <div className={`relative min-w-0 flex-1 ${tab === "dashboard" ? "xl:flex xl:min-h-0 xl:flex-col xl:overflow-hidden" : ""}`}>
        <div className="glass-header sticky top-0 z-20" inert={lockedOverlay ? true : undefined} aria-hidden={lockedOverlay ? true : undefined}>
          <div className="flex items-center gap-3 px-4 py-3 sm:px-6">
            <button onClick={() => setOpen(true)} aria-label="Buka menu" aria-expanded={open} className="btn-ghost rounded-xl p-2 lg:hidden">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" aria-hidden><path d="M4 7h16M4 12h16M4 17h16" /></svg>
            </button>
            <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-gradient-to-br from-indigo-600 to-violet-600 text-white shadow-[0_6px_16px_-6px_rgba(99,102,241,0.7)]" aria-hidden>
              <TabIcon tab={tab} />
            </span>
            <div className="min-w-0">
              <p className="truncate text-[10px] font-bold uppercase tracking-[0.18em] text-zinc-400">
                Threadline <span className="mx-1 text-zinc-300">/</span> <span className="text-indigo-500">{TAB_META[tab].label}</span>
              </p>
              <h1 className="-mt-0.5 truncate text-lg font-extrabold tracking-tight sm:text-xl">{TAB_META[tab].label}</h1>
              <p className="hidden truncate text-xs text-zinc-500 sm:block">{TAB_META[tab].desc}</p>
            </div>
            <span className={`ml-auto inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-semibold ${
              realtime === "on" ? "bg-emerald-100 text-emerald-900 ring-1 ring-inset ring-emerald-300"
              : realtime === "connecting" ? "bg-zinc-100 text-zinc-600 ring-1 ring-inset ring-zinc-300"
              : "bg-amber-100 text-amber-900 ring-1 ring-inset ring-amber-300"
            }`}>
              <span className={`h-1.5 w-1.5 rounded-full ${realtime === "on" ? "bg-emerald-500" : realtime === "connecting" ? "bg-zinc-400" : "bg-amber-500"}`} />
              <span className="hidden sm:inline">{realtime === "on" ? "Realtime" : realtime === "connecting" ? "Menghubungkan…" : "Terputus"}</span>
            </span>
          </div>
          <div className="h-[2px] bg-gradient-to-r from-indigo-500 via-violet-500 to-amber-400" aria-hidden />
        </div>
        <main inert={lockedOverlay ? true : undefined} aria-hidden={lockedOverlay ? true : undefined} className={`mx-auto w-full max-w-[1440px] px-4 py-5 sm:px-6 ${tab === "dashboard" ? "xl:flex xl:min-h-0 xl:flex-1 xl:flex-col xl:overflow-hidden" : ""}`}>{children}</main>
        {lockedOverlay && (
          <div
            className="fixed inset-0 z-50 flex items-center justify-center bg-white/35 p-5 backdrop-blur-md lg:left-20 xl:left-64"
            role="dialog"
            aria-modal="true"
            aria-labelledby="locked-overlay-title"
          >
            {lockedOverlay}
          </div>
        )}
      </div>
    </div>
  );
}
