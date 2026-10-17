"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { useReadyStore } from "@/lib/store-context";
import { formatJobCode, hasOperationsAccess, isTerlambat, isUrgen, type Job, type JobStatus } from "@/lib/domain";

export type Toast = (m: string) => void;

export const STATUS_COLORS: Record<JobStatus, string> = {
  "Belum Ditugaskan": "bg-zinc-100 text-zinc-700 ring-1 ring-inset ring-zinc-300",
  "Antre": "bg-amber-100 text-amber-900 ring-1 ring-inset ring-amber-300",
  "Dikerjakan": "bg-blue-100 text-blue-900 ring-1 ring-inset ring-blue-300",
  "Preview": "bg-violet-100 text-violet-900 ring-1 ring-inset ring-violet-300",
  "MintaACC": "bg-violet-100 text-violet-900 ring-1 ring-inset ring-violet-300",
  "Revisi": "bg-orange-100 text-orange-900 ring-1 ring-inset ring-orange-300",
  "ACC": "bg-emerald-100 text-emerald-900 ring-1 ring-inset ring-emerald-300",
  "Finished": "bg-teal-100 text-teal-900 ring-1 ring-inset ring-teal-300",
  "Dibatalkan": "bg-rose-100 text-rose-900 ring-1 ring-inset ring-rose-300",
};

export function useNow(intervalMs = 30_000) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(t);
  }, [intervalMs]);
  return now;
}

export function Badge({ job, now, sla }: { job: Job; now: number; sla: number }) {
  return (
    <span className="flex flex-wrap gap-1">
      <span className={`rounded-full px-2 py-0.5 text-xs font-semibold shadow-sm ${STATUS_COLORS[job.status]}`}>{job.status}</span>
      {job.priority === "express" && <span className="rounded-full bg-gradient-to-r from-rose-600 to-orange-500 px-2 py-0.5 text-xs font-semibold text-white shadow-sm">Express</span>}
      {isUrgen(job, sla, now) && <span className="rounded-full bg-gradient-to-r from-amber-500 to-amber-400 px-2 py-0.5 text-xs font-semibold text-white shadow-sm">Urgen</span>}
      {isTerlambat(job, now) && <span className="rounded-full bg-zinc-900 px-2 py-0.5 text-xs font-semibold text-white shadow-sm">Terlambat</span>}
    </span>
  );
}

export function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="glass-card relative overflow-hidden p-4">
      <span className="absolute inset-y-0 left-0 w-1 bg-gradient-to-b from-indigo-500 to-violet-500" aria-hidden />
      <div className="pl-2 text-xs font-medium uppercase tracking-wide text-zinc-500">{label}</div>
      <div className="pl-2 text-2xl font-extrabold tracking-tight">{value}</div>
    </div>
  );
}

export function Empty({ text }: { text: string }) {
  return <div className="glass-soft border-dashed p-6 text-center text-sm text-zinc-500">{text}</div>;
}

export function JobFilters({ q, setQ, status, setStatus }: { q: string; setQ: (v: string) => void; status: string; setStatus: (v: string) => void }) {
  return (
    <div className="flex flex-wrap gap-2">
      <input
        className="input min-w-52 flex-1 px-3 py-2 text-sm"
        placeholder="Cari ID / tim / penerima…"
        value={q}
        onChange={(e) => setQ(e.target.value)}
      />
      <Select
        ariaLabel="Filter status"
        className="w-full sm:w-48"
        value={status}
        onChange={setStatus}
        options={[{ value: "", label: "Semua status" }, ...Object.keys(STATUS_COLORS).map((s) => ({ value: s, label: s }))]}
      />
    </div>
  );
}

export interface SelectOption {
  value: string;
  label: ReactNode;
  hint?: string;
  disabled?: boolean;
}

// Dropdown custom pengganti <select> native agar konsisten dengan design system.
// List opsi memakai panel glass + check pada pilihan aktif.
export function Select({ value, onChange, options, placeholder, ariaLabel, className, disabled = false }: {
  value: string;
  onChange: (v: string) => void;
  options: SelectOption[];
  placeholder?: string;
  ariaLabel?: string;
  className?: string;
  disabled?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [menuPosition, setMenuPosition] = useState<{ top: number; left: number; width: number; maxHeight: number } | null>(null);
  const boxRef = useRef<HTMLDivElement>(null);
  const menuRef = useRef<HTMLUListElement>(null);

  useEffect(() => {
    if (!open) return;
    const positionMenu = () => {
      const box = boxRef.current;
      if (!box) return;
      const rect = box.getBoundingClientRect();
      const viewportPadding = 12;
      const width = Math.min(Math.max(rect.width, 240), window.innerWidth - viewportPadding * 2);
      const left = Math.max(viewportPadding, Math.min(rect.left, window.innerWidth - width - viewportPadding));
      const desiredHeight = Math.min(256, Math.max(64, options.length * 54 + 12));
      const spaceBelow = window.innerHeight - rect.bottom - viewportPadding;
      const spaceAbove = rect.top - viewportPadding;
      const placeAbove = spaceAbove > spaceBelow && spaceBelow < desiredHeight;
      const availableSpace = Math.max(48, placeAbove ? spaceAbove : spaceBelow);
      const maxHeight = Math.max(48, Math.min(256, availableSpace - 8));
      const panelHeight = Math.min(desiredHeight, maxHeight);
      const top = placeAbove
        ? Math.max(viewportPadding, rect.top - panelHeight - 8)
        : Math.min(rect.bottom + 8, window.innerHeight - panelHeight - viewportPadding);
      setMenuPosition({ top, left, width, maxHeight });
    };
    const onDown = (e: MouseEvent) => {
      const target = e.target as Node;
      if (!boxRef.current?.contains(target) && !menuRef.current?.contains(target)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    positionMenu();
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    window.addEventListener("resize", positionMenu);
    window.addEventListener("scroll", positionMenu, true);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
      window.removeEventListener("resize", positionMenu);
      window.removeEventListener("scroll", positionMenu, true);
    };
  }, [open, options.length]);

  const current = options.find((o) => o.value === value);

  return (
    <div ref={boxRef} className={`relative ${className ?? ""}`}>
      <button
        type="button" aria-haspopup="listbox" aria-expanded={open} aria-label={ariaLabel}
        disabled={disabled}
        onClick={() => setOpen(!open)}
        className="input flex w-full items-center justify-between gap-2 px-3 py-2 text-left text-sm disabled:cursor-not-allowed disabled:opacity-60"
      >
        <span className="min-w-0 flex-1 truncate">{current?.label ?? <span className="text-zinc-400">{placeholder ?? "— pilih —"}</span>}</span>
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden
          className={`shrink-0 text-zinc-400 transition-transform ${open ? "rotate-180" : ""}`}>
          <path d="m6 9 6 6 6-6" />
        </svg>
      </button>
      {open && menuPosition && typeof document !== "undefined" && createPortal(
        <ul
          ref={menuRef}
          role="listbox"
          aria-label={ariaLabel}
          style={{ position: "fixed", top: menuPosition.top, left: menuPosition.left, width: menuPosition.width, maxHeight: menuPosition.maxHeight }}
          className="z-[1000] overflow-y-auto overscroll-contain rounded-2xl border border-indigo-100 bg-white p-1.5 shadow-[0_20px_50px_-12px_rgba(30,27,75,0.4)] ring-1 ring-black/5"
        >
          {options.length === 0 ? (
            <li className="px-3 py-3 text-center text-xs text-zinc-500">Belum ada opsi tersedia.</li>
          ) : options.map((o) => {
            const active = o.value === value;
            return (
              <li key={o.value || "(semua)"} role="option" aria-selected={active} aria-disabled={o.disabled || undefined}>
                <button
                  type="button"
                  disabled={o.disabled}
                  onClick={() => { onChange(o.value); setOpen(false); }}
                  className={`flex w-full items-center gap-2 rounded-xl px-3 py-2.5 text-left text-sm transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-indigo-500 disabled:cursor-not-allowed disabled:opacity-50 ${active ? "bg-gradient-to-r from-indigo-50 to-violet-50 font-bold text-indigo-950" : "text-zinc-800 hover:bg-zinc-50"}`}
                >
                  <span className="min-w-0 flex-1">
                    <span className="block truncate">{o.label}</span>
                    {o.hint && <span className="mt-0.5 block text-[11px] font-medium text-zinc-500">{o.hint}</span>}
                  </span>
                  {active && (
                    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden className="shrink-0 text-indigo-600">
                      <path d="M20 6 9 17l-5-5" />
                    </svg>
                  )}
                </button>
              </li>
            );
          })}
        </ul>,
        document.body,
      )}
    </div>
  );
}

export function useFilteredJobs() {
  const { data, currentProfile } = useReadyStore();
  const [q, setQ] = useState("");
  const [status, setStatus] = useState("");
  const base = hasOperationsAccess(currentProfile.role) ? data.jobs : data.jobs.filter((j) => j.assigneeId === currentProfile.id);
  const nameOf = (id?: string) => data.profiles.find((p) => p.id === id)?.name ?? "-";
  const filtered = base.filter((j) => {
    if (status && j.status !== status) return false;
    if (!q.trim()) return true;
    const s = q.toLowerCase();
    return formatJobCode(j.id).toLowerCase().includes(s) || j.id.toLowerCase().includes(s) || j.tim.toLowerCase().includes(s) || nameOf(j.assigneeId).toLowerCase().includes(s);
  }).sort((a, b) => {
    const ex = (b.priority === "express" ? 1 : 0) - (a.priority === "express" ? 1 : 0);
    if (ex !== 0) return ex;
    return +new Date(b.createdAt) - +new Date(a.createdAt);
  });
  return { filtered, q, setQ, status, setStatus, nameOf };
}
