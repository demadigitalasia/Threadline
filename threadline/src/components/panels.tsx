"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useReadyStore } from "@/lib/store-context";
import { activeJobCount, formatJobCode, formatWIB, hasOperationsAccess, isFull, isOnline, isTerlambat, isUrgen } from "@/lib/domain";
import { Badge, Empty, JobFilters, Select, useFilteredJobs, type Toast } from "./threadline-ui";
import { CreateJob } from "./job-forms";
import { JobDetail } from "./job-detail";

export function FreelancerAvailabilityNotifier({ onToast }: { onToast: Toast }) {
  const { data, currentProfile } = useReadyStore();
  const freelances = useMemo(() => data.profiles.filter((p) => p.role === "freelance"), [data.profiles]);
  const previousAvailability = useRef<Map<string, string> | null>(null);

  useEffect(() => {
    const next = new Map(freelances.map((profile) => [profile.id, profile.availabilityStatus]));
    if (!hasOperationsAccess(currentProfile.role)) {
      previousAvailability.current = next;
      return;
    }
    const previous = previousAvailability.current;
    if (previous) {
      for (const profile of freelances) {
        const oldStatus = previous.get(profile.id);
        if (oldStatus === profile.availabilityStatus || profile.availabilityStatus === "pending" || !isOnline(profile.lastSeen, Date.now())) continue;
        onToast(profile.availabilityStatus === "ready"
          ? `${profile.name} siap menerima job.`
          : `${profile.name} tidak siap menerima job.`);
      }
    }
    previousAvailability.current = next;
  }, [currentProfile.role, freelances, onToast]);

  return null;
}

export function PresenceCapacity({ now, list }: { now: number; list?: boolean }) {
  const { data } = useReadyStore();
  const freelances = useMemo(() => data.profiles
    .filter((p) => p.role === "freelance")
    .sort((a, b) => {
      const rank = (profile: typeof a) => {
        const online = isOnline(profile.lastSeen, now);
        return online && profile.availabilityStatus === "ready" ? 0
          : online && profile.availabilityStatus === "pending" ? 1
          : online ? 2 : 3;
      };
      return rank(a) - rank(b) || a.name.localeCompare(b.name);
    }), [data.profiles, now]);
  const onlineFreelances = freelances.filter((p) => isOnline(p.lastSeen, now));
  const readyFreelances = onlineFreelances.filter((p) => p.availabilityStatus === "ready");
  const pendingFreelances = onlineFreelances.filter((p) => p.availabilityStatus === "pending");
  const unavailableFreelances = onlineFreelances.filter((p) => p.availabilityStatus === "unavailable");

  return (
      <div className={`glass-card p-3 sm:p-4 ${list ? "xl:flex xl:min-h-0 xl:flex-1 xl:flex-col xl:overflow-hidden" : ""}`}>
      <div className="mb-2.5 flex shrink-0 flex-wrap items-center justify-between gap-2">
        <div className="text-sm font-bold">Tim freelance <span className="font-medium text-zinc-500">(khusus Admin)</span></div>
        <div className="text-[11px] tabular-nums text-zinc-500">
          {onlineFreelances.length}/{freelances.length} online • {readyFreelances.length} siap • {unavailableFreelances.length} tidak siap • {pendingFreelances.length} belum check-in • batas {data.maxActive} aktif
        </div>
      </div>
      <div className={list ? "grid gap-1.5 xl:min-h-0 xl:flex-1 xl:content-start xl:overflow-y-auto xl:overscroll-contain xl:pr-1" : "grid gap-2.5 sm:grid-cols-2 xl:grid-cols-4"}>
        {freelances.map((p) => {
          const n = activeJobCount(data.jobs, p.id);
          const online = isOnline(p.lastSeen, now);
          const ready = online && p.availabilityStatus === "ready";
          const pending = online && p.availabilityStatus === "pending";
          const full = isFull(data.jobs, p.id, data.maxActive);
          return (
            <div key={p.id} className={`tile-soft ${list ? "p-2" : "p-3"}`}>
              <div className="flex items-center gap-2.5">
                <span className={`relative flex shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-indigo-500 to-violet-500 font-extrabold text-white ${list ? "h-8 w-8 text-xs" : "h-9 w-9 text-sm"}`} aria-hidden>
                  {(p.name.trim()[0] ?? "?").toUpperCase()}
                  <span className={`absolute -bottom-0.5 -right-0.5 h-3 w-3 rounded-full ring-2 ring-white ${online ? "bg-emerald-500" : "bg-zinc-400"}`} title={online ? "online" : "offline"} />
                </span>
                <div className="min-w-0 flex-1">
                  <div className="truncate text-sm font-bold">{p.name}</div>
                  <div className={`${list ? "text-[10px]" : "text-[11px]"} tabular-nums text-zinc-500`}>{n}/{data.maxActive} aktif • {online ? (ready ? "siap menerima" : pending ? "belum check-in" : "tidak siap") : "offline"}</div>
                </div>
                <span className={`shrink-0 rounded-md px-1.5 py-0.5 text-[10px] font-bold ${!online ? "bg-zinc-100 text-zinc-500" : ready ? "bg-emerald-100 text-emerald-800" : pending ? "bg-indigo-100 text-indigo-800" : "bg-amber-100 text-amber-800"}`}>
                  {!online ? "Offline" : ready ? "Siap" : pending ? "Check-in" : "Tidak siap"}
                </span>
                {full && <span className="shrink-0 rounded-md bg-amber-100 px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider text-amber-800 ring-1 ring-inset ring-amber-300">penuh</span>}
              </div>
              <div className={`${list ? "mt-1 h-1" : "mt-2 h-1.5"} overflow-hidden rounded-full bg-zinc-200/70`}>
                <div
                  className={`h-full rounded-full ${full ? "bg-gradient-to-r from-amber-500 to-orange-400" : "bg-gradient-to-r from-indigo-500 to-violet-500"}`}
                  style={{ width: `${Math.min(100, Math.round((n / data.maxActive) * 100))}%` }}
                />
              </div>
            </div>
          );
        })}
        {freelances.length === 0 && <div className="text-xs text-zinc-500">Belum ada freelance.</div>}
      </div>
    </div>
  );
}

function todayWIB(now: number): string {
  return new Intl.DateTimeFormat("id-ID", { timeZone: "Asia/Jakarta", weekday: "long", day: "numeric", month: "long", year: "numeric" }).format(new Date(now));
}

type Flag = "semua" | "preview" | "urgen" | "late" | "express";

export function Dashboard({ onToast, now }: { onToast: Toast; now: number }) {
  const { data, currentProfile } = useReadyStore();
  const f = useFilteredJobs();
  const [openId, setOpenId] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);
  const isAdmin = hasOperationsAccess(currentProfile.role);
  const scope = isAdmin ? data.jobs : data.jobs.filter((j) => j.assigneeId === currentProfile.id);
  const myActive = activeJobCount(data.jobs, currentProfile.id);
  const express = scope.filter((j) => j.priority === "express" && !["Finished", "Dibatalkan"].includes(j.status));
  const urgen = scope.filter((j) => isUrgen(j, data.slaHours, now));
  const late = scope.filter((j) => isTerlambat(j, now));
  const waitPreview = scope.filter((j) => j.status === "Preview");
  const [flag, setFlag] = useState<Flag>("semua");

  const flags: { id: Flag; label: string; n: number }[] = [
    { id: "semua", label: "Semua", n: scope.length },
    ...(isAdmin ? [{ id: "preview" as Flag, label: "Menunggu Preview", n: waitPreview.length }] : []),
    { id: "urgen", label: "Urgen", n: urgen.length },
    { id: "late", label: "Terlambat", n: late.length },
    { id: "express", label: "Express", n: express.length },
  ];
  const flagged = f.filtered.filter((j) =>
    flag === "semua" ? true
    : flag === "preview" ? j.status === "Preview"
    : flag === "urgen" ? isUrgen(j, data.slaHours, now)
    : flag === "late" ? isTerlambat(j, now)
    : j.priority === "express" && !["Finished", "Dibatalkan"].includes(j.status),
  );
  const openIndex = flagged.findIndex((job) => job.id === openId);
  const navigation = openIndex < 0 ? undefined : {
    position: openIndex + 1,
    total: flagged.length,
    previousId: flagged[openIndex - 1]?.id,
    nextId: flagged[openIndex + 1]?.id,
  };

  return (
    <div className="space-y-3 xl:flex xl:min-h-0 xl:flex-1 xl:flex-col xl:gap-3 xl:space-y-0">
      {/* Hero sapaan */}
      <div className="auth-side relative overflow-hidden rounded-3xl p-5 text-white sm:p-6">
        <div className="relative flex flex-wrap items-center gap-4">
          <div className="min-w-0 flex-1">
            <p className="text-xs font-medium uppercase tracking-widest text-white/65">{todayWIB(now)}</p>
            <h2 className="mt-0.5 truncate text-xl font-extrabold tracking-tight sm:text-2xl">Halo, {currentProfile.name}</h2>
            <p className="mt-0.5 text-sm text-white/75">
              {isAdmin
                ? `${scope.filter((j) => !["Finished", "Dibatalkan"].includes(j.status)).length} job berjalan • ${data.profiles.filter((p) => p.role === "freelance").length} freelance`
                : `${myActive}/${data.maxActive} slot aktif terpakai • ${scope.filter((j) => j.status === "Finished").length} selesai`}
            </p>
          </div>
          {isAdmin ? (
            <button className="relative rounded-2xl bg-white px-4 py-2.5 text-sm font-extrabold text-indigo-900 shadow-lg transition-transform hover:-translate-y-0.5" onClick={() => setShowCreate(true)}>
              + Buat job
            </button>
          ) : (
            <div className="auth-feature relative px-4 py-2.5 text-center">
              <div className="text-xl font-extrabold tabular-nums">{myActive}/{data.maxActive}</div>
              <div className="text-[10px] font-bold uppercase tracking-widest text-white/65">aktif</div>
            </div>
          )}
        </div>
      </div>

      <div className="grid items-start gap-3 xl:min-h-0 xl:flex-1 xl:grid-cols-[minmax(0,1fr)_300px] xl:grid-rows-1 xl:items-stretch">
        <div className="min-w-0 space-y-3 xl:flex xl:min-h-0 xl:flex-col xl:gap-3 xl:space-y-0">
          <div className="glass-card relative overflow-hidden p-3.5 sm:p-4">
            <div aria-hidden className="pointer-events-none absolute inset-x-0 top-0 h-1 bg-gradient-to-r from-indigo-500 via-violet-500 to-fuchsia-400" />
            <div className="relative space-y-3">
            <div className="flex items-center justify-between gap-3">
              <div className="flex min-w-0 items-center gap-2.5">
                <span className="grid size-9 shrink-0 place-items-center rounded-xl bg-gradient-to-br from-indigo-600 to-violet-600 text-white shadow-sm shadow-indigo-500/20" aria-hidden>
                  <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M8 6h13M8 12h13M8 18h13" /><path d="M3 6h.01M3 12h.01M3 18h.01" /></svg>
                </span>
                <div className="min-w-0">
                  <h2 className="text-sm font-extrabold text-zinc-900">Daftar job</h2>
                  <p className="mt-0.5 text-[11px] text-zinc-500">Pilih job untuk membuka ruang kerja.</p>
                </div>
              </div>
              <span className="inline-flex shrink-0 items-center gap-1.5 rounded-xl border border-indigo-100 bg-gradient-to-br from-indigo-50 to-violet-50 px-2.5 py-1.5 text-[11px] font-semibold text-indigo-700">
                <span className="font-extrabold tabular-nums">{flagged.length}</span> hasil
              </span>
            </div>
            <div role="group" aria-label="Filter cepat job" className="flex items-center gap-1.5 overflow-x-auto rounded-xl bg-zinc-100/75 p-1.5">
              {flags.map((fl) => (
                <button
                  key={fl.id} type="button" aria-pressed={flag === fl.id} onClick={() => setFlag(fl.id)}
                  className={`inline-flex shrink-0 items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-xs font-bold transition-all ${flag === fl.id ? "bg-gradient-to-r from-indigo-600 to-violet-600 text-white shadow-md shadow-indigo-500/20" : "bg-white/80 text-zinc-600 ring-1 ring-inset ring-zinc-200/80 hover:bg-white hover:text-zinc-900"}`}
                >
                  {fl.label} <span className={`rounded-md px-1 py-0.5 text-[10px] leading-none tabular-nums ${flag === fl.id ? "bg-white/20 text-white" : "bg-zinc-100 text-zinc-500"}`}>{fl.n}</span>
                </button>
              ))}
            </div>
            <div className="rounded-xl border border-zinc-200/70 bg-white/65 p-2">
              <JobFilters q={f.q} setQ={f.setQ} status={f.status} setStatus={f.setStatus} />
            </div>
            </div>
          </div>

          {flagged.length === 0 && <Empty text="Tidak ada job. Coba ubah filter atau buat job baru." />}
          <div className="overflow-x-auto rounded-2xl border border-zinc-200/80 bg-white/85 shadow-sm shadow-indigo-950/5 xl:min-h-0 xl:flex-1 xl:overscroll-contain xl:overflow-auto">
              <table className="w-full min-w-[740px] border-collapse text-left">
                <caption className="sr-only">Daftar job. Pilih kode atau nama tim untuk membuka detail.</caption>
                <thead className="sticky top-0 z-10 bg-gradient-to-r from-indigo-50/95 via-white to-violet-50/95 shadow-[0_1px_0_rgba(228,228,231,0.9)]">
                  <tr className="border-b border-indigo-100/80">
                    <th scope="col" className="px-4 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Job</th>
                    <th scope="col" className="px-3 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Jenis / penerima</th>
                    <th scope="col" className="px-3 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Status</th>
                    <th scope="col" className="px-3 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Deadline</th>
                    <th scope="col" className="px-4 py-3 text-right text-[10px] font-bold uppercase tracking-wider text-zinc-500">Fee</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-100/90">
                  {flagged.map((j) => {
                    const lateJob = isTerlambat(j, now);
                    const isSelected = openId === j.id;
                    return (
                      <tr key={j.id} onClick={() => setOpenId(j.id)} className={`group cursor-pointer transition-colors hover:bg-indigo-50/45 ${isSelected ? "bg-indigo-50/75" : ""}`}>
                        <td className="px-4 py-3">
                          <button type="button" aria-label={`Buka detail ${formatJobCode(j.id)} · ${j.tim}`} aria-pressed={isSelected} className="rounded-md text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500 focus-visible:ring-offset-2">
                            <span className="block font-mono text-xs font-extrabold tracking-wide text-indigo-700">{formatJobCode(j.id)}</span>
                            <span className="mt-0.5 block max-w-48 truncate text-sm font-bold text-zinc-900 group-hover:text-indigo-800">{j.tim}</span>
                          </button>
                        </td>
                        <td className="px-3 py-3">
                          <span className="block max-w-44 truncate text-xs font-semibold text-zinc-700">{j.jenis} · {j.qty} pcs</span>
                          <span className="mt-0.5 block max-w-44 truncate text-[11px] text-zinc-500">{f.nameOf(j.assigneeId)}</span>
                        </td>
                        <td className="px-3 py-3"><Badge job={j} now={now} sla={data.slaHours} /></td>
                        <td className="whitespace-nowrap px-3 py-3 text-xs tabular-nums">
                          <span className={lateJob ? "font-bold text-rose-700" : "text-zinc-600"}>{formatWIB(j.deadline)}</span>
                          {lateJob && <span className="mt-0.5 block text-[10px] font-bold uppercase tracking-wide text-rose-600">Terlambat</span>}
                        </td>
                        <td className="whitespace-nowrap px-4 py-3 text-right text-xs font-extrabold tabular-nums text-zinc-900">Rp{j.fee.toLocaleString("id-ID")}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
          </div>

          {showCreate && <CreateJob onClose={() => setShowCreate(false)} onToast={onToast} />}
        </div>
        <aside className="space-y-3 xl:flex xl:min-h-0 xl:flex-col xl:gap-3 xl:space-y-0 xl:overflow-hidden">
          <div className="glass-card shrink-0 p-4">
            <div className="text-sm font-bold">Ringkasan</div>
            <dl className="mt-1 divide-y divide-zinc-200/70 text-sm">
              {(
                [
                  ["Terlihat", scope.length],
                  ["Express aktif", express.length],
                  ["Urgen", urgen.length],
                  [isAdmin ? "Menunggu Preview" : "Terlambat", isAdmin ? waitPreview.length : late.length],
                ] as [string, number][]
              ).map(([label, value]) => (
                <div key={label} className="flex items-center justify-between py-1.5">
                  <dt className="text-zinc-500">{label}</dt>
                  <dd className="font-extrabold tabular-nums">{value}</dd>
                </div>
              ))}
            </dl>
          </div>
          {isAdmin && <PresenceCapacity now={now} list />}
        </aside>
      </div>
      {openId && <JobDetail key={openId} jobId={openId} onClose={() => setOpenId(null)} onNavigate={setOpenId} navigation={navigation} onToast={onToast} now={now} />}
    </div>
  );
}

function ageText(ms: number): string {
  const h = Math.floor(ms / 3600_000);
  if (h < 1) return "<1 jam";
  if (h < 24) return `${h} jam`;
  const d = Math.floor(h / 24);
  return `${d} hari${h % 24 ? ` ${h % 24} jam` : ""}`;
}

export function Intake({ onToast, now }: { onToast: Toast; now: number }) {
  const { data, currentProfile } = useReadyStore();
  const isAdmin = hasOperationsAccess(currentProfile.role);
  const [openId, setOpenId] = useState<string | null>(null);
  const [q, setQ] = useState("");
  const [sort, setSort] = useState<"fifo" | "baru" | "deadline" | "fee">("fifo");
  const jobs = (isAdmin ? data.jobs : data.jobs.filter((j) => j.assigneeId === currentProfile.id))
    .filter((j) => j.status === "Belum Ditugaskan");

  const totalQty = jobs.reduce((a, j) => a + j.qty, 0);
  const totalFee = jobs.reduce((a, j) => a + j.fee, 0);
  const oldest = jobs.length ? Math.max(...jobs.map((j) => now - new Date(j.createdAt).getTime())) : 0;

  const shown = jobs
    .filter((j) => {
      if (!q.trim()) return true;
      const s = q.toLowerCase();
      return formatJobCode(j.id).toLowerCase().includes(s) || j.id.toLowerCase().includes(s) || j.tim.toLowerCase().includes(s) || j.jenis.toLowerCase().includes(s);
    })
    .sort((a, b) => {
      if (sort === "baru") return +new Date(b.createdAt) - +new Date(a.createdAt);
      if (sort === "deadline") return +new Date(a.deadline) - +new Date(b.deadline);
      if (sort === "fee") return b.fee - a.fee;
      return +new Date(a.createdAt) - +new Date(b.createdAt); // FIFO: antre terlama dulu
    });

  return (
    <div className="space-y-3">
      {/* Hero */}
      <div className="auth-side relative overflow-hidden rounded-3xl p-5 text-white sm:p-6">
        <div className="relative flex flex-wrap items-end justify-between gap-4">
          <div>
            <h2 className="text-xl font-extrabold tracking-tight sm:text-2xl">Antrean Intake</h2>
            <p className="mt-0.5 text-sm text-white/75">
              {isAdmin
                ? "Job Belum Ditugaskan — belum memakai kapasitas siapa pun. Tanpa pengingat otomatis."
                : "Antrean intake hanya terlihat oleh Admin. Job muncul di dashboard setelah ditugaskan kepadamu."}
            </p>
          </div>
          {isAdmin && jobs.length > 0 && (
            <div className="flex gap-2">
              {[
                { v: String(jobs.length), l: "job" },
                { v: String(totalQty), l: "pcs" },
                { v: `Rp${(totalFee / 1000000).toLocaleString("id-ID", { maximumFractionDigits: 1 })} jt`, l: "potensi" },
                { v: ageText(oldest), l: "tunggu terlama" },
              ].map((s) => (
                <div key={s.l} className="auth-feature px-3.5 py-2 text-center">
                  <div className="truncate text-base font-extrabold tabular-nums sm:text-lg">{s.v}</div>
                  <div className="text-[10px] font-bold uppercase tracking-widest text-white/65">{s.l}</div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {isAdmin && (
        <div className="flex flex-wrap items-center gap-2">
          <input
            className="input min-w-44 flex-1 px-3 py-1.5 text-sm" placeholder="Cari ID / tim / jenis…"
            value={q} onChange={(e) => setQ(e.target.value)}
          />
          <Select
            ariaLabel="Urutkan antrean" className="w-full sm:w-60" value={sort} onChange={(v) => setSort(v as typeof sort)}
            options={[
              { value: "fifo", label: "Antre terlama (FIFO)", hint: "Urutan antrean yang adil" },
              { value: "baru", label: "Terbaru dibuat" },
              { value: "deadline", label: "Deadline terdekat" },
              { value: "fee", label: "Fee terbesar" },
            ]}
          />
        </div>
      )}

      <div className={`grid min-w-0 items-start gap-3 ${openId ? "lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]" : ""}`}>
        <div className="min-w-0">
          {shown.length === 0 ? (
            <Empty text={jobs.length === 0 ? (isAdmin ? "Antrean kosong. Buat job baru dari Dashboard." : "Tidak ada job menunggumu di antrean.") : "Tidak cocok dengan pencarian."} />
          ) : (
            <div className="max-h-[68vh] min-h-56 overflow-auto overscroll-contain rounded-2xl border border-zinc-200/80 bg-white/85 shadow-sm shadow-indigo-950/5">
              <table className="w-full min-w-[980px] border-collapse text-left">
                <caption className="sr-only">Daftar job intake yang belum ditugaskan. Pilih baris untuk membuka penugasan.</caption>
                <thead className="sticky top-0 z-10 bg-gradient-to-r from-indigo-50/95 via-white to-violet-50/95 shadow-[0_1px_0_rgba(228,228,231,0.9)]">
                  <tr>
                    <th scope="col" className="px-4 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Job</th>
                    <th scope="col" className="px-3 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Jenis / qty</th>
                    <th scope="col" className="px-3 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Prioritas</th>
                    <th scope="col" className="whitespace-nowrap px-3 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Deadline</th>
                    <th scope="col" className="whitespace-nowrap px-3 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Waktu antre</th>
                    <th scope="col" className="px-3 py-3 text-right text-[10px] font-bold uppercase tracking-wider text-zinc-500">Fee</th>
                    {isAdmin && <th scope="col" className="px-4 py-3 text-right text-[10px] font-bold uppercase tracking-wider text-zinc-500">Aksi</th>}
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-100/90">
                  {shown.map((j, i) => {
                    const wait = now - new Date(j.createdAt).getTime();
                    const late = now >= new Date(j.deadline).getTime();
                    const isSelected = openId === j.id;
                    return (
                      <tr
                        key={j.id}
                        onClick={() => setOpenId(j.id)}
                        className={`group cursor-pointer transition-colors hover:bg-indigo-50/45 ${isSelected ? "bg-indigo-50/80" : ""}`}
                      >
                        <td className="px-4 py-3">
                          <button
                            type="button"
                            aria-label={`Buka penugasan ${formatJobCode(j.id)} · ${j.tim}`}
                            onClick={() => setOpenId(j.id)}
                            className="rounded-md text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500 focus-visible:ring-offset-2"
                          >
                            <span className="flex items-center gap-2">
                              <span className="block font-mono text-xs font-extrabold tracking-wide text-indigo-700">{formatJobCode(j.id)}</span>
                              {sort === "fifo" && <span className="rounded-md bg-zinc-100 px-1.5 py-0.5 font-mono text-[10px] font-bold text-zinc-500">#{i + 1}</span>}
                            </span>
                            <span className="mt-0.5 block max-w-56 truncate text-sm font-bold text-zinc-900 group-hover:text-indigo-800">{j.tim}</span>
                            <span className="mt-0.5 block max-w-56 truncate text-[11px] text-zinc-500">{j.brief || "Tanpa brief"}</span>
                          </button>
                        </td>
                        <td className="px-3 py-3 text-xs">
                          <span className="block max-w-40 truncate font-semibold text-zinc-700">{j.jenis}</span>
                          <span className="mt-0.5 block text-[11px] text-zinc-500">{j.qty} pcs</span>
                        </td>
                        <td className="px-3 py-3">
                          {j.priority === "express" ? (
                            <span className="rounded-full bg-gradient-to-r from-rose-600 to-orange-500 px-2 py-0.5 text-[11px] font-bold text-white shadow-sm">Express</span>
                          ) : (
                            <span className="rounded-full bg-zinc-100 px-2 py-0.5 text-[11px] font-semibold text-zinc-600 ring-1 ring-inset ring-zinc-200">Normal</span>
                          )}
                        </td>
                        <td className="whitespace-nowrap px-3 py-3 text-xs tabular-nums">
                          <span className={late ? "font-bold text-rose-700" : "text-zinc-600"}>{formatWIB(j.deadline)}</span>
                          {late && <span className="mt-0.5 block text-[10px] font-bold uppercase tracking-wide text-rose-600">Terlambat</span>}
                        </td>
                        <td className="whitespace-nowrap px-3 py-3 text-xs tabular-nums text-zinc-600">{ageText(wait)}</td>
                        <td className="whitespace-nowrap px-3 py-3 text-right text-xs font-extrabold tabular-nums text-zinc-900">Rp{j.fee.toLocaleString("id-ID")}</td>
                        {isAdmin && (
                          <td className="px-4 py-3 text-right">
                            <button
                              type="button"
                              aria-label={`Tugaskan ${formatJobCode(j.id)} · ${j.tim}`}
                              onClick={() => setOpenId(j.id)}
                              className="whitespace-nowrap rounded-lg bg-indigo-50 px-2.5 py-1.5 text-[11px] font-bold text-indigo-700 ring-1 ring-inset ring-indigo-200 transition hover:bg-indigo-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500"
                            >
                              Tugaskan →
                            </button>
                          </td>
                        )}
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>
        {openId && <JobDetail key={openId} jobId={openId} onClose={() => setOpenId(null)} onToast={onToast} now={now} />}
      </div>
    </div>
  );
}

export function Arsip({ onToast, now }: { onToast: Toast; now: number }) {
  const { data, currentProfile } = useReadyStore();
  const [openId, setOpenId] = useState<string | null>(null);
  const [seg, setSeg] = useState<"semua" | "Finished" | "Dibatalkan">("semua");
  const [q, setQ] = useState("");
  const [sort, setSort] = useState<"baru" | "fee" | "deadline">("baru");
  const base = (hasOperationsAccess(currentProfile.role) ? data.jobs : data.jobs.filter((j) => j.assigneeId === currentProfile.id))
    .filter((j) => j.status === "Finished" || j.status === "Dibatalkan");
  const nFinished = base.filter((j) => j.status === "Finished").length;
  const nBatal = base.length - nFinished;
  const nameOf = (id?: string) => data.profiles.find((p) => p.id === id)?.name ?? "-";
  const atOf = (jobId: string, type: string) => data.events.find((e) => e.jobId === jobId && e.type === type)?.createdAt;

  const shown = base
    .filter((j) => seg === "semua" || j.status === seg)
    .filter((j) => {
      if (!q.trim()) return true;
      const s = q.toLowerCase();
      return formatJobCode(j.id).toLowerCase().includes(s) || j.id.toLowerCase().includes(s) || j.tim.toLowerCase().includes(s) || nameOf(j.assigneeId).toLowerCase().includes(s);
    })
    .sort((a, b) => {
      if (sort === "fee") return (b.approvedFee ?? b.fee) - (a.approvedFee ?? a.fee);
      if (sort === "deadline") return +new Date(a.deadline) - +new Date(b.deadline);
      const ta = atOf(a.id, a.status === "Finished" ? "finish" : "cancel") ?? a.createdAt;
      const tb = atOf(b.id, b.status === "Finished" ? "finish" : "cancel") ?? b.createdAt;
      return +new Date(tb) - +new Date(ta);
    });

  const segBtn = (v: typeof seg, label: string, n: number) => (
    <button
      key={v} onClick={() => setSeg(v)}
      className={`rounded-full px-3.5 py-1.5 text-sm font-semibold transition-all ${seg === v ? "bg-zinc-900 text-white shadow" : "bg-white/70 text-zinc-600 ring-1 ring-inset ring-zinc-200 hover:bg-white"}`}
    >
      {label} <span className={`ml-1 rounded-full px-1.5 text-[11px] tabular-nums ${seg === v ? "bg-white/20" : "bg-zinc-100"}`}>{n}</span>
    </button>
  );

  return (
    <div className="space-y-3">
      {/* Hero */}
      <div className="auth-side relative overflow-hidden rounded-3xl p-5 text-white sm:p-6">
        <div className="relative flex flex-wrap items-end justify-between gap-3">
          <div>
            <h2 className="text-xl font-extrabold tracking-tight sm:text-2xl">Arsip & Batal</h2>
            <p className="mt-0.5 text-sm text-white/75">Status terminal — riwayat tetap tersedia, tak bisa diubah.</p>
          </div>
          <div className="flex gap-2">
            <div className="auth-feature px-4 py-2 text-center">
            <div className="text-xl font-extrabold tabular-nums">{nFinished}</div>
              <div className="text-[10px] font-bold uppercase tracking-widest text-white/65">Finished</div>
            </div>
            <div className="auth-feature px-4 py-2 text-center">
              <div className="text-xl font-extrabold tabular-nums">{nBatal}</div>
              <div className="text-[10px] font-bold uppercase tracking-widest text-white/65">Dibatalkan</div>
            </div>
          </div>
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <div className="flex gap-1.5">
          {segBtn("semua", "Semua", base.length)}
          {segBtn("Finished", "Finished", nFinished)}
          {segBtn("Dibatalkan", "Dibatalkan", nBatal)}
        </div>
        <input
          className="input min-w-44 flex-1 px-3 py-1.5 text-sm" placeholder="Cari ID / tim / penerima…"
          value={q} onChange={(e) => setQ(e.target.value)}
        />
        <Select
          ariaLabel="Urutkan arsip" className="w-full sm:w-56" value={sort} onChange={(v) => setSort(v as typeof sort)}
          options={[
            { value: "baru", label: "Terbaru selesai" },
            { value: "fee", label: "Fee terbesar" },
            { value: "deadline", label: "Deadline terdekat" },
          ]}
        />
      </div>

      <div className={`grid min-w-0 items-start gap-3 ${openId ? "lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]" : ""}`}>
        <div className="min-w-0">
          {shown.length === 0 ? (
            <Empty text={base.length === 0 ? "Belum ada arsip." : "Tidak cocok dengan filter."} />
          ) : (
            <div className="max-h-[68vh] min-h-56 overflow-auto overscroll-contain rounded-2xl border border-zinc-200/80 bg-white/85 shadow-sm shadow-indigo-950/5">
              <table className="w-full min-w-[850px] border-collapse text-left">
                <caption className="sr-only">Arsip job selesai dan dibatalkan. Pilih job untuk membuka detail.</caption>
                <thead className="sticky top-0 z-10 bg-gradient-to-r from-indigo-50/95 via-white to-violet-50/95 shadow-[0_1px_0_rgba(228,228,231,0.9)]">
                  <tr>
                    <th scope="col" className="px-4 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Job</th>
                    <th scope="col" className="px-3 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Jenis / penerima</th>
                    <th scope="col" className="px-3 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Status</th>
                    <th scope="col" className="whitespace-nowrap px-3 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Deadline</th>
                    <th scope="col" className="whitespace-nowrap px-3 py-3 text-[10px] font-bold uppercase tracking-wider text-zinc-500">Diarsipkan</th>
                    <th scope="col" className="px-4 py-3 text-right text-[10px] font-bold uppercase tracking-wider text-zinc-500">Fee / keterangan</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-100/90">
                  {shown.map((j) => {
                    const isFinished = j.status === "Finished";
                    const at = atOf(j.id, isFinished ? "finish" : "cancel") ?? j.createdAt;
                    const isSelected = openId === j.id;
                    return (
                      <tr
                        key={j.id}
                        onClick={() => setOpenId(j.id)}
                        className={`group cursor-pointer transition-colors hover:bg-indigo-50/45 ${isSelected ? "bg-indigo-50/80" : ""}`}
                      >
                        <td className="px-4 py-3">
                          <button
                            type="button"
                            aria-label={`Buka detail ${formatJobCode(j.id)} · ${j.tim}`}
                            aria-pressed={isSelected}
                            onClick={() => setOpenId(j.id)}
                            className="rounded-md text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500 focus-visible:ring-offset-2"
                          >
                            <span className="block font-mono text-xs font-extrabold tracking-wide text-indigo-700">{formatJobCode(j.id)}</span>
                            <span className="mt-0.5 block max-w-52 truncate text-sm font-bold text-zinc-900 group-hover:text-indigo-800">{j.tim}</span>
                          </button>
                        </td>
                        <td className="px-3 py-3">
                          <span className="block max-w-48 truncate text-xs font-semibold text-zinc-700">{j.jenis} · {j.qty} pcs</span>
                          <span className="mt-0.5 block max-w-48 truncate text-[11px] text-zinc-500">{nameOf(j.assigneeId)}</span>
                        </td>
                        <td className="px-3 py-3"><Badge job={j} now={now} sla={data.slaHours} /></td>
                        <td className="whitespace-nowrap px-3 py-3 text-xs tabular-nums text-zinc-600">{formatWIB(j.deadline)}</td>
                        <td className="whitespace-nowrap px-3 py-3 text-xs tabular-nums text-zinc-600">{formatWIB(at)}</td>
                        <td className="max-w-64 px-4 py-3 text-right">
                          {isFinished ? (
                            <span className="whitespace-nowrap text-xs font-extrabold tabular-nums text-emerald-700">Rp{(j.approvedFee ?? j.fee).toLocaleString("id-ID")}</span>
                          ) : (
                            <span className="block truncate text-xs italic text-zinc-500" title={j.cancellationReason ?? "Dibatalkan"}>“{j.cancellationReason ?? "Dibatalkan"}”</span>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>
        {openId && <JobDetail key={openId} jobId={openId} onClose={() => setOpenId(null)} onToast={onToast} now={now} />}
      </div>
    </div>
  );
}
