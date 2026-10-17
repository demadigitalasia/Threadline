"use client";

import { useEffect, useRef, useState } from "react";
import { useReadyStore } from "@/lib/store-context";
import { canViewGlobalFeeRecap, formatJobCode, hasOperationsAccess } from "@/lib/domain";
import { formatWIB, isOnline } from "@/lib/domain";
import { Empty, Select, type Toast } from "./threadline-ui";
import { FinancePayments } from "./finance-payments";

function dayLabel(iso: string, now: number): string {
  const d = new Date(iso);
  const fmt = (t: number) =>
    new Intl.DateTimeFormat("id-ID", { timeZone: "Asia/Jakarta", day: "2-digit", month: "short", year: "numeric" }).format(new Date(t));
  if (fmt(d.getTime()) === fmt(now)) return "Hari ini";
  if (fmt(d.getTime()) === fmt(Date.now() - 86400_000)) return "Kemarin";
  return fmt(d.getTime());
}

function timeOnly(iso: string): string {
  return new Intl.DateTimeFormat("id-ID", { timeZone: "Asia/Jakarta", hour: "2-digit", minute: "2-digit" }).format(new Date(iso));
}

export function ChatPanel({ onToast }: { onToast: Toast }) {
  const { data, currentProfile, sendMessage } = useReadyStore();
  const isAdmin = hasOperationsAccess(currentProfile.role);
  const threads = isAdmin ? data.threads : data.threads.filter((t) => t.freelanceId === currentProfile.id);
  const [activeId, setActiveId] = useState(threads[0]?.id ?? "");
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [q, setQ] = useState("");
  const [nowTick, setNowTick] = useState(() => Date.now());
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const t = setInterval(() => setNowTick(Date.now()), 30_000);
    return () => clearInterval(t);
  }, []);

  const safeActiveId = threads.some((t) => t.id === activeId) ? activeId : (threads[0]?.id ?? "");
  const msgs = data.messages.filter((m) => m.threadId === safeActiveId);
  const nameOf = (id: string) => data.profiles.find((p) => p.id === id)?.name ?? id;
  const presenceOf = (fid: string) => {
    const p = data.profiles.find((x) => x.id === fid);
    return p ? isOnline(p.lastSeen, nowTick) : false;
  };
  const lastOf = (tid: string) => {
    const ms = data.messages.filter((m) => m.threadId === tid);
    return ms.length ? ms[ms.length - 1] : null;
  };
  const shownThreads = threads.filter((t) =>
    !q.trim() || nameOf(t.freelanceId).toLowerCase().includes(q.trim().toLowerCase()),
  );
  const activeName = threads.find((t) => t.id === safeActiveId) ? nameOf(threads.find((t) => t.id === safeActiveId)!.freelanceId) : "-";
  const activeFid = threads.find((t) => t.id === safeActiveId)?.freelanceId;

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
  }, [msgs.length, safeActiveId]);

  // Kelompokkan divider hari tanpa mutasi saat render
  const grouped: { m: (typeof msgs)[number]; day: string; showDay: boolean }[] = [];
  {
    const seen = new Set<string>();
    for (const m of msgs) {
      const day = dayLabel(m.createdAt, nowTick);
      const showDay = !seen.has(day);
      seen.add(day);
      grouped.push({ m, day, showDay });
    }
  }
  return (
    <div className="space-y-3">
      <div className="auth-side relative overflow-hidden rounded-3xl px-5 py-4 text-white sm:px-6">
        <div className="relative flex flex-wrap items-center gap-3">
          <div>
            <h2 className="text-xl font-extrabold tracking-tight">Chat</h2>
            <p className="mt-0.5 text-sm text-white/75">
              {isAdmin ? `${threads.length} thread • Admin dan Super Admin dapat membaca & membalas` : "Thread langsung dengan Admin dan Super Admin • tetap ada sebelum dapat job"}
            </p>
          </div>
          <span className="ml-auto rounded-full bg-white/12 px-3 py-1 text-xs font-bold ring-1 ring-inset ring-white/25">
            {msgs.length} pesan di thread ini
          </span>
        </div>
      </div>

      <div className="grid gap-3 lg:grid-cols-3">
        {/* Daftar thread */}
        <div className="glass-card flex max-h-[70vh] flex-col p-3">
          {isAdmin && threads.length > 1 && (
            <input
              className="input mb-2 px-3 py-1.5 text-sm" placeholder="Cari freelance…"
              value={q} onChange={(e) => setQ(e.target.value)}
            />
          )}
          <div className="space-y-1.5 overflow-y-auto pr-0.5">
            {shownThreads.map((t) => {
              const last = lastOf(t.id);
              const active = safeActiveId === t.id;
              return (
                <button
                  key={t.id} onClick={() => setActiveId(t.id)}
                  className={`w-full rounded-2xl px-3 py-2.5 text-left transition-all ${active ? "bg-gradient-to-r from-indigo-600 to-violet-600 text-white shadow-lg" : "tile-soft hover:bg-white"}`}
                >
                  <div className="flex items-center gap-2.5">
                    <span className={`relative flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-sm font-extrabold ${active ? "bg-white/20 text-white" : "bg-gradient-to-br from-indigo-500 to-violet-500 text-white"}`} aria-hidden>
                      {(nameOf(t.freelanceId).trim()[0] ?? "?").toUpperCase()}
                      {isAdmin && (
                        <span className={`absolute -bottom-0.5 -right-0.5 h-3 w-3 rounded-full ring-2 ${active ? "ring-indigo-600" : "ring-white"} ${presenceOf(t.freelanceId) ? "bg-emerald-500" : "bg-zinc-400"}`} title={presenceOf(t.freelanceId) ? "online" : "offline"} />
                      )}
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="flex items-baseline justify-between gap-2">
                        <span className="truncate text-sm font-bold">{nameOf(t.freelanceId)}</span>
                        {last && <span className={`shrink-0 text-[11px] tabular-nums ${active ? "text-white/70" : "text-zinc-400"}`}>{timeOnly(last.createdAt)}</span>}
                      </span>
                      <span className={`block truncate text-xs ${active ? "text-white/75" : "text-zinc-500"}`}>
                        {last ? `${last.senderId === currentProfile.id ? "Anda: " : `${last.senderName}: `}${last.text}` : "Belum ada pesan"}
                      </span>
                    </span>
                  </div>
                </button>
              );
            })}
            {shownThreads.length === 0 && <div className="p-3 text-xs text-zinc-500">{threads.length === 0 ? "Tidak ada thread." : "Tidak cocok dengan pencarian."}</div>}
          </div>
        </div>

        {/* Ruang pesan */}
        <div className="glass-card flex max-h-[70vh] flex-col p-3 sm:p-4 lg:col-span-2">
          <div className="flex items-center gap-2.5 border-b border-zinc-200/70 px-1 pb-2.5">
            <span className="flex h-9 w-9 items-center justify-center rounded-full bg-gradient-to-br from-indigo-500 to-violet-500 text-sm font-extrabold text-white" aria-hidden>
              {(activeName.trim()[0] ?? "?").toUpperCase()}
            </span>
            <div className="min-w-0">
              <div className="truncate text-sm font-extrabold">{activeName}</div>
              <div className="text-[11px] text-zinc-500">
                {activeFid && isAdmin ? (presenceOf(activeFid) ? "● online" : "○ offline") : "Maks 500 karakter per pesan • realtime"}
              </div>
            </div>
          </div>

          <div className="min-h-48 flex-1 space-y-1.5 overflow-y-auto px-1 py-3">
            {msgs.length === 0 && (
              <div className="flex h-full flex-col items-center justify-center gap-2 py-10 text-center">
                <span className="flex h-14 w-14 items-center justify-center rounded-3xl bg-gradient-to-br from-indigo-100 to-violet-100 text-indigo-500" aria-hidden>
                  <svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M21 11.5a8.5 8.5 0 0 1-8.5 8.5c-1.5 0-3-.4-4.2-1L3 20l1.1-4.3A8.5 8.5 0 1 1 21 11.5z" /></svg>
                </span>
                <p className="text-sm font-bold">Belum ada pesan</p>
                <p className="max-w-60 text-xs text-zinc-500">Mulai percakapan — pesan baru muncul otomatis via realtime.</p>
              </div>
            )}
            {grouped.map(({ m, day, showDay }) => {
              const mine = m.senderId === currentProfile.id;
              return (
                <div key={m.id}>
                  {showDay && (
                    <div className="flex items-center gap-2 py-1.5">
                      <span className="h-px flex-1 bg-zinc-200" />
                      <span className="rounded-full bg-zinc-100 px-2.5 py-0.5 text-[11px] font-bold text-zinc-500">{day}</span>
                      <span className="h-px flex-1 bg-zinc-200" />
                    </div>
                  )}
                  <div className={`flex ${mine ? "justify-end" : "justify-start"}`}>
                    <div className={`max-w-[82%] rounded-2xl px-3 py-1.5 text-sm sm:max-w-[75%] ${mine ? "msg-own rounded-br-md text-white" : "msg-other rounded-bl-md"}`}>
                      {!mine && <div className="text-[11px] font-bold text-indigo-700">{m.senderName}</div>}
                      <div className="whitespace-pre-wrap break-words">{m.text}</div>
                      <div className={`mt-0.5 text-right text-[10px] tabular-nums ${mine ? "text-white/70" : "text-zinc-400"}`}>{timeOnly(m.createdAt)}</div>
                    </div>
                  </div>
                </div>
              );
            })}
            <div ref={bottomRef} />
          </div>

          <form
            className="mt-2 flex items-end gap-2 border-t border-zinc-200/70 pt-2.5"
            onSubmit={(e) => {
              e.preventDefault();
              if (!draft.trim()) return;
              setBusy(true);
              void sendMessage(safeActiveId, draft).then((r) => {
                setBusy(false);
                if (!r.ok) { onToast(r.error ?? "Gagal"); return; }
                setDraft("");
              });
            }}
          >
            <input
              className="input flex-1 px-3.5 py-2.5 text-sm" placeholder="Tulis pesan… (Enter untuk kirim)"
              value={draft} onChange={(e) => setDraft(e.target.value)} maxLength={500}
            />
            <span className="hidden self-center text-xs tabular-nums text-zinc-400 sm:inline">{draft.length}/500</span>
            <button
              className="btn-primary flex shrink-0 items-center gap-1.5 rounded-xl px-4 py-2.5 text-sm font-semibold text-white"
              disabled={busy || !draft.trim()}
              aria-label="Kirim pesan"
            >
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                <path d="m22 2-7 20-4-9-9-4 20-7z" /><path d="M22 2 11 13" />
              </svg>
              <span className="hidden sm:inline">Kirim</span>
            </button>
          </form>
        </div>
      </div>
    </div>
  );
}

export function Rekap({ onToast }: { onToast: Toast }) {
  const { data, currentProfile } = useReadyStore();
  if (currentProfile.role === "finance") return <FinancePayments onToast={onToast} />;
  const canViewAll = canViewGlobalFeeRecap(currentProfile.role);
  const finished = data.jobs.filter((j) => j.status === "Finished");
  const visible = canViewAll ? finished : finished.filter((j) => (j.approvedForProfileId ?? j.assigneeId) === currentProfile.id);
  const by: Record<string, { name: string; total: number; count: number }> = {};
  for (const j of visible) {
    const pid = j.approvedForProfileId ?? j.assigneeId ?? "?";
    const name = data.profileNames[pid] ?? pid;
    by[pid] = by[pid] ?? { name, total: 0, count: 0 };
    by[pid].total += j.approvedFee ?? j.fee;
    by[pid].count += 1;
  }
  const rows = Object.values(by).sort((a, b) => b.total - a.total);
  const total = rows.reduce((a, r) => a + r.total, 0);
  const max = rows[0]?.total ?? 1;
  const finishedAt = (jobId: string) => data.jobs.find((job) => job.id === jobId)?.finishedAt
    ?? data.events.find((event) => event.jobId === jobId && event.type === "finish")?.createdAt;

  return (
    <div className="space-y-3">
      {/* Hero */}
      <div className="auth-side relative overflow-hidden rounded-3xl p-5 text-white sm:p-6">
        <div className="relative flex flex-wrap items-end justify-between gap-4">
          <div>
            <h2 className="text-xl font-extrabold tracking-tight sm:text-2xl">Rekap Fee</h2>
            <p className="mt-0.5 text-sm text-white/75">Fee job direkap setelah file asli dikirim • bukan bukti bayar.</p>
          </div>
          <div className="text-right">
            <div className="text-3xl font-extrabold tabular-nums tracking-tight sm:text-4xl">Rp{total.toLocaleString("id-ID")}</div>
            <div className="mt-0.5 text-xs font-medium uppercase tracking-widest text-white/65">
              {visible.length} job Finished • {rows.length} penerima
              {visible.length > 0 && ` • rata-rata Rp${Math.round(total / visible.length).toLocaleString("id-ID")}`}
            </div>
          </div>
        </div>
      </div>

      {rows.length === 0 && <Empty text="Belum ada job Finished." />}

      {/* Papan peringkat */}
      {rows.length > 0 && (
        <div className="glass-card p-4 sm:p-5">
          <div className="text-sm font-bold">Per penerima fee</div>
          <ul className="mt-3 space-y-3">
            {rows.map((r, i) => (
              <li key={r.name}>
                <div className="flex items-center gap-3">
                  <span className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-xl text-sm font-extrabold tabular-nums ${
                    i === 0 ? "bg-gradient-to-br from-amber-300 to-rose-400 text-indigo-950"
                    : i === 1 ? "bg-zinc-200 text-zinc-700 ring-1 ring-inset ring-zinc-300"
                    : i === 2 ? "bg-orange-100 text-orange-900 ring-1 ring-inset ring-orange-300"
                    : "bg-white/70 text-zinc-500 ring-1 ring-inset ring-zinc-200"
                  }`} aria-hidden>
                    {i + 1}
                  </span>
                  <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-indigo-500 to-violet-500 text-sm font-extrabold text-white" aria-hidden>
                    {(r.name.trim()[0] ?? "?").toUpperCase()}
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-baseline justify-between gap-x-2">
                      <span className="truncate text-sm font-bold">{r.name}</span>
                      <span className="text-sm font-extrabold tabular-nums">Rp{r.total.toLocaleString("id-ID")}</span>
                    </div>
                    <div className="mt-1 h-2 overflow-hidden rounded-full bg-zinc-200/70">
                      <div
                        className="h-full rounded-full bg-gradient-to-r from-indigo-500 via-violet-500 to-fuchsia-400"
                        style={{ width: `${Math.max(4, Math.round((r.total / max) * 100))}%` }}
                      />
                    </div>
                    <div className="mt-0.5 text-[11px] tabular-nums text-zinc-500">{r.count} job Finished</div>
                  </div>
                </div>
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Rincian job */}
      {visible.length > 0 && (
        <div className="glass-card p-4 sm:p-5">
          <div className="text-sm font-bold">Rincian job Finished</div>
          <ul className="mt-2 divide-y divide-zinc-200/70">
            {visible
              .slice()
              .sort((a, b) => +new Date(finishedAt(b.id) ?? b.createdAt) - +new Date(finishedAt(a.id) ?? a.createdAt))
              .map((j) => {
                const at = finishedAt(j.id);
                return (
                  <li key={j.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-2.5 text-sm">
                    <span className="font-mono text-xs font-bold">{formatJobCode(j.id)}</span>
                    <span className="min-w-0 flex-1 truncate font-medium">{j.tim} <span className="text-zinc-400">• {j.jenis}</span></span>
                    <span className="text-xs text-zinc-500">{at ? formatWIB(at) : ""}</span>
                    <span className="text-sm font-extrabold tabular-nums">Rp{(j.approvedFee ?? j.fee).toLocaleString("id-ID")}</span>
                  </li>
                );
              })}
          </ul>
          <p className="mt-2 text-[11px] text-zinc-500">Tanggal rekap mengikuti saat file asli dikirim. Fee mengikuti penerima yang disetujui saat preview.</p>
        </div>
      )}
    </div>
  );
}
