"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { useReadyStore } from "@/lib/store-context";
import {
  ACCEPTED_FILE_EXTENSIONS, activeJobCount, allowedTransitions, formatJobCode, formatWIB, hasOperationsAccess, isOnline, validateFileKind,
  type Job,
} from "@/lib/domain";
import { Badge, Select, type Toast } from "./threadline-ui";

function Info({ label, value, accent }: { label: string; value: ReactNode; accent?: boolean }) {
  return (
    <div className={`rounded-xl px-3 py-2 ring-1 ring-inset ${accent ? "bg-gradient-to-br from-indigo-50 to-violet-50 ring-indigo-200" : "bg-white/70 ring-zinc-200/80"}`}>
      <div className="text-[10px] font-bold uppercase tracking-widest text-zinc-400">{label}</div>
      <div className={`mt-0.5 text-sm ${accent ? "font-extrabold text-indigo-950" : "font-semibold"}`}>{value}</div>
    </div>
  );
}

function SectionHeading({ title, description }: { title: string; description: string }) {
  return (
    <div className="relative overflow-hidden bg-gradient-to-r from-indigo-700 via-violet-700 to-fuchsia-600 px-4 py-4 text-white shadow-md shadow-indigo-900/15 sm:px-5">
      <div aria-hidden className="pointer-events-none absolute -right-8 -top-16 size-40 rounded-full bg-white/10 blur-2xl" />
      <div className="relative flex items-center gap-3">
        <span className="grid size-10 shrink-0 place-items-center rounded-xl bg-white/15 text-white ring-1 ring-inset ring-white/20" aria-hidden>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M4 5h16M4 12h16M4 19h16" /><circle cx="2.5" cy="5" r=".5" fill="currentColor" /><circle cx="2.5" cy="12" r=".5" fill="currentColor" /><circle cx="2.5" cy="19" r=".5" fill="currentColor" /></svg>
        </span>
        <div className="min-w-0">
          <p className="text-[9px] font-bold uppercase tracking-[0.18em] text-white/65">Threadline · detail job</p>
          <h3 className="mt-0.5 text-sm font-extrabold text-white sm:text-base">{title}</h3>
          <p className="mt-0.5 text-xs leading-4 text-white/75">{description}</p>
        </div>
      </div>
    </div>
  );
}

type JobNavigation = { position: number; total: number; previousId?: string; nextId?: string };

export function JobDetail({ jobId, onClose, onToast, now, navigation, onNavigate }: {
  jobId: string; onClose: () => void; onToast: Toast; now: number;
  navigation?: JobNavigation; onNavigate?: (jobId: string) => void;
}) {
  const ctx = useReadyStore();
  const { data, currentProfile } = ctx;
  const job = data.jobs.find((j) => j.id === jobId);
  const [assignTo, setAssignTo] = useState(job?.assigneeId ?? "");
  const [assignmentReason, setAssignmentReason] = useState("");
  const [cancellationReason, setCancellationReason] = useState("");
  const [reviewReason, setReviewReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [editBrief, setEditBrief] = useState(job?.brief ?? "");
  const [activeSection, setActiveSection] = useState("job-overview");
  const contentRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => { document.body.style.overflow = previousOverflow; };
  }, []);

  const selectSection = (sectionId: string) => {
    setActiveSection(sectionId);
    if (contentRef.current) contentRef.current.scrollTop = 0;
  };

  if (!job) return null;
  const isAdmin = hasOperationsAccess(currentProfile.role);
  const isAssignedFreelancer = currentProfile.role === "freelance" && job.assigneeId === currentProfile.id;
  const transitions = allowedTransitions(job, currentProfile.role).filter(() => {
    if (currentProfile.role === "freelance") return job.assigneeId === currentProfile.id;
    return true;
  });
  const freelances = data.profiles
    .filter((p) => p.role === "freelance")
    .sort((a, b) => {
      const rank = (profile: typeof a) => {
        const online = isOnline(profile.lastSeen, now);
        return online && profile.availabilityStatus === "ready" ? 0 : online && profile.availabilityStatus === "pending" ? 1 : online ? 2 : 3;
      };
      return rank(a) - rank(b) || a.name.localeCompare(b.name);
    });
  const jobEvents = data.events.filter((event) => event.jobId === job.id);
  const workflowSteps = ["Antre", "Dikerjakan", "Preview", "ACC", "Finished"] as const;
  const workflowStatus = job.status === "Revisi" ? "Dikerjakan" : job.status === "MintaACC" ? "Preview" : job.status;
  const workflowIndex = workflowSteps.indexOf(workflowStatus as (typeof workflowSteps)[number]);
  const workflowMessage = job.status === "Belum Ditugaskan"
    ? "Menunggu Admin menugaskan freelancer."
    : job.status === "Antre"
      ? "Freelancer yang ditugaskan memulai pekerjaan dari tab Alur kerja."
      : job.status === "Dikerjakan" || job.status === "Revisi"
        ? "Unggah beberapa gambar preview, lalu ajukan ke Admin untuk ditinjau."
        : job.status === "Preview" || job.status === "MintaACC"
          ? isAdmin ? "Tinjau gambar preview, lalu setujui atau minta revisi." : "Preview sedang menunggu keputusan Admin."
          : job.status === "ACC"
            ? isAdmin ? "Preview disetujui. Menunggu file asli CDR dari freelancer." : "Preview disetujui. Kirim file asli CDR untuk menyelesaikan job."
            : "File asli CDR sudah dikirim. Job selesai.";
  const activityLabel: Record<string, string> = {
    preview_submit: "Preview diajukan",
    preview_approve: "Preview disetujui Admin",
    preview_revision: "Revisi preview diminta",
    finish: "File asli dikirim · Finished",
    status: "Status berubah",
    assign: "Job ditugaskan",
    reassign: "Job dialihkan",
    cancel: "Job dibatalkan",
    submit: "Pengajuan lama",
    approve: "ACC alur lama",
  };

  const run = (p: Promise<{ ok: boolean; error?: string }>, okMsg?: string) => {
    setBusy(true);
    void p.then((r) => {
      setBusy(false);
      onToast(r.ok ? (okMsg ?? "Tersimpan") : (r.error ?? "Gagal"));
    });
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center overflow-hidden bg-slate-950/70 p-2 backdrop-blur-sm sm:p-4 lg:p-6" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
      <section aria-label={`Detail job ${formatJobCode(job.id)}`} className="flex h-full min-h-0 w-full max-w-6xl flex-col overflow-hidden rounded-2xl border border-white/60 bg-white shadow-[0_32px_100px_-24px_rgba(15,23,42,0.7)] sm:rounded-3xl" role="dialog" aria-modal="true">
        <header className="relative flex shrink-0 items-start gap-2.5 border-b border-violet-100 bg-gradient-to-br from-indigo-100/80 via-violet-50/90 to-fuchsia-100/70 px-3 py-3 sm:gap-4 sm:px-5 sm:py-3.5">
          <div aria-hidden className="pointer-events-none absolute inset-x-0 bottom-0 h-px bg-gradient-to-r from-indigo-300 via-violet-400 to-fuchsia-300" />
          <button aria-label="Kembali ke daftar job" title="Kembali" className="btn-ghost relative mt-0.5 inline-flex size-9 shrink-0 items-center justify-center rounded-xl text-zinc-700" onClick={onClose}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d="m15 18-6-6 6-6" /><path d="M20 12H9" /></svg>
          </button>
          <div className="relative min-w-0 flex-1 pt-0.5">
            <div className="flex min-w-0 flex-wrap items-center gap-1.5">
              <h2 className="font-mono text-xs font-extrabold leading-5 tracking-tight text-zinc-800 sm:text-sm">{formatJobCode(job.id)}</h2>
              <span className="rounded-md bg-zinc-100 px-1.5 py-0.5 font-mono text-[9px] font-semibold uppercase leading-3 tracking-wide text-zinc-500">Rev {job.revision}</span>
              {navigation && <span aria-label={`Job ${navigation.position} dari ${navigation.total} hasil filter`} title={`${navigation.position} dari ${navigation.total} job hasil filter`} className="rounded-md border border-zinc-200 bg-white px-1.5 py-0.5 text-[9px] font-medium leading-3 tabular-nums text-zinc-500">{navigation.position} / {navigation.total}</span>}
            </div>
            <div className="mt-0.5 flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-0.5">
              <span className="max-w-full truncate text-sm font-bold leading-5 text-zinc-900 sm:text-base">{job.tim}</span>
              <span className="text-[10px] font-medium leading-4 text-zinc-400 sm:text-[11px]">Dibuat {formatWIB(job.createdAt)} WIB</span>
            </div>
            <div className="mt-1.5 flex flex-wrap items-center gap-1.5"><Badge job={job} now={now} sla={data.slaHours} /></div>
          </div>
          {navigation && onNavigate && (
            <div className="relative flex shrink-0 items-center gap-1 rounded-xl bg-white/75 p-1 ring-1 ring-inset ring-indigo-100/80">
              <button type="button" aria-label="Buka job sebelumnya" title="Job sebelumnya" disabled={!navigation.previousId} onClick={() => navigation.previousId && onNavigate(navigation.previousId)} className="grid size-8 place-items-center rounded-lg text-zinc-600 transition hover:bg-white hover:text-indigo-700 disabled:cursor-not-allowed disabled:opacity-30">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d="m15 18-6-6 6-6" /></svg>
              </button>
              <span className="px-0.5 text-[10px] font-bold tabular-nums text-zinc-500 sm:hidden">{navigation.position}/{navigation.total}</span>
              <button type="button" aria-label="Buka job berikutnya" title="Job berikutnya" disabled={!navigation.nextId} onClick={() => navigation.nextId && onNavigate(navigation.nextId)} className="grid size-8 place-items-center rounded-lg text-zinc-600 transition hover:bg-white hover:text-indigo-700 disabled:cursor-not-allowed disabled:opacity-30">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d="m9 18 6-6-6-6" /></svg>
              </button>
            </div>
          )}
        </header>
        <nav aria-label="Navigasi detail job" role="tablist" className="flex shrink-0 gap-1 overflow-x-auto border-b border-zinc-200/80 bg-white px-3 py-2 sm:px-5">
          {([
            ["job-overview", "Ringkasan"], ["job-workflow", "Alur kerja"], ["job-files", "Preview & file"], ["job-activity", "Aktivitas"],
          ] as const).map(([sectionId, label]) => (
            <button key={sectionId} id={`${sectionId}-tab`} type="button" role="tab" aria-selected={activeSection === sectionId} aria-controls={sectionId} tabIndex={activeSection === sectionId ? 0 : -1} onClick={() => selectSection(sectionId)} onKeyDown={(event) => {
              const tabs = ["job-overview", "job-workflow", "job-files", "job-activity"];
              const currentIndex = tabs.indexOf(sectionId);
              const nextIndex = event.key === "ArrowRight" ? (currentIndex + 1) % tabs.length : event.key === "ArrowLeft" ? (currentIndex - 1 + tabs.length) % tabs.length : event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : -1;
              if (nextIndex < 0) return;
              event.preventDefault();
              const nextTab = tabs[nextIndex];
              selectSection(nextTab);
              document.getElementById(`${nextTab}-tab`)?.focus();
            }} className={`shrink-0 rounded-lg px-3 py-2 text-xs font-bold transition ${activeSection === sectionId ? "bg-gradient-to-r from-indigo-50 to-violet-50 text-indigo-800 ring-1 ring-inset ring-indigo-100" : "text-zinc-500 hover:bg-zinc-100 hover:text-zinc-900"}`}>
              {label}
            </button>
          ))}
        </nav>
        <div ref={contentRef} className="min-h-0 flex-1 overflow-y-auto overscroll-contain bg-zinc-50/70 p-3 sm:p-5">
        <div className="mx-auto w-full max-w-5xl">
        <section id="job-overview" role="tabpanel" aria-labelledby="job-overview-tab" tabIndex={0} hidden={activeSection !== "job-overview"} className="glass-card-gradient overflow-hidden p-0">
        <SectionHeading title="Ringkasan pekerjaan" description="Detail inti, tenggat, penerima, dan brief pekerjaan." />
        <div className="space-y-3.5 p-3.5 sm:p-5">
        {job.status !== "Dibatalkan" && (
          <div className="rounded-2xl border border-indigo-100 bg-gradient-to-br from-white via-indigo-50/40 to-violet-50/60 p-3.5 shadow-sm sm:p-4">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="text-xs font-extrabold uppercase tracking-wider text-indigo-950">Alur pekerjaan</div>
              <span className="rounded-lg bg-white/80 px-2 py-1 text-[10px] font-bold text-indigo-700 ring-1 ring-inset ring-indigo-100">{job.status}</span>
            </div>
            <ol aria-label="Tahapan job" className="mt-3 grid grid-cols-5 gap-1.5">
              {workflowSteps.map((step, index) => {
                const complete = workflowIndex >= 0 && index < workflowIndex || job.status === "Finished";
                const current = workflowIndex === index;
                return (
                  <li key={step} aria-current={current ? "step" : undefined} className="min-w-0">
                    <div className={`h-1.5 rounded-full ${complete || current ? "bg-gradient-to-r from-indigo-500 to-violet-500" : "bg-zinc-200"}`} />
                    <div className={`mt-1 truncate text-[9px] font-bold sm:text-[11px] ${current ? "text-indigo-800" : complete ? "text-violet-700" : "text-zinc-400"}`}>{step}</div>
                  </li>
                );
              })}
            </ol>
            <div className="mt-2 flex flex-wrap items-center justify-between gap-2">
              <p className="text-xs leading-5 text-zinc-600">{workflowMessage}</p>
              {isAssignedFreelancer && job.status === "Antre" && (
                <button className="btn-primary shrink-0 rounded-xl px-3.5 py-2 text-xs font-bold text-white" disabled={busy} onClick={() => run(ctx.transition(job.id, "Dikerjakan"), "Pekerjaan dimulai")}>
                  Mulai Kerjakan
                </button>
              )}
            </div>
          </div>
        )}
        <div className="mt-4 grid grid-cols-2 gap-2">
          <Info label="Jenis / Qty" value={`${job.jenis} • ${job.qty} pcs`} />
          <Info label="Prioritas" value={job.priority} />
          <Info label="Deadline" value={`${formatWIB(job.deadline)} WIB`} />
          <Info label="Fee" accent value={`Rp${job.fee.toLocaleString("id-ID")}`} />
          <div className="col-span-2">
            <Info label="Penerima" value={data.profiles.find((p) => p.id === job.assigneeId)?.name ?? "Belum ditugaskan"} />
          </div>
        </div>
        {job.approvedFee != null && (
          <div className="mt-3 rounded-xl bg-gradient-to-r from-emerald-50 to-teal-50 px-3 py-2.5 text-xs font-semibold text-emerald-900 ring-1 ring-inset ring-emerald-200/80">
            Preview di-ACC · fee Rp{job.approvedFee.toLocaleString("id-ID")} → {data.profiles.find((p) => p.id === job.approvedForProfileId)?.name} (dibekukan)
          </div>
        )}
        <div className="mt-3 rounded-2xl bg-gradient-to-br from-white to-indigo-50/40 p-3 ring-1 ring-inset ring-indigo-100/80">
          <label htmlFor={`job-brief-${job.id}`} className="text-[10px] font-bold uppercase tracking-widest text-zinc-400">Brief pekerjaan</label>
          {isAdmin ? (
            <div className="mt-1.5 grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end">
              <textarea id={`job-brief-${job.id}`} rows={3} className="input min-h-20 w-full resize-y px-3 py-2 text-sm leading-5" placeholder="Tulis detail pekerjaan, bahan, warna, ukuran, atau catatan lain..." value={editBrief} onChange={(e) => setEditBrief(e.target.value)} />
              <button className="btn-ghost min-h-9 shrink-0 rounded-lg px-3 text-xs font-semibold" disabled={busy} onClick={() => run(ctx.updateJobFields(job.id, { brief: editBrief }), "Brief disimpan")}>Simpan brief</button>
            </div>
          ) : (
            <p className="mt-1.5 whitespace-pre-wrap text-sm leading-5 text-zinc-700">{job.brief || "Belum ada brief."}</p>
          )}
        </div>
        {job.status === "Dibatalkan" && <div className="mt-2 rounded-xl bg-rose-50 p-2.5 text-sm ring-1 ring-inset ring-rose-200">Dibatalkan: {job.cancellationReason} • {job.cancelledAt ? formatWIB(job.cancelledAt) : ""}</div>}
        {job.ref && <div className="mt-2 text-xs text-zinc-500">Ref: {job.ref}</div>}
        </div>
        </section>

        <section id="job-workflow" role="tabpanel" aria-labelledby="job-workflow-tab" tabIndex={0} hidden={activeSection !== "job-workflow"} className="glass-card-gradient overflow-hidden p-0">
        <SectionHeading title="Alur kerja" description="Atur penugasan, status, dan tindakan untuk job ini." />
        <div className="space-y-4 p-3.5 sm:p-5">
        {isAdmin && !["Preview", "ACC", "Finished", "Dibatalkan"].includes(job.status) && (
          <div className="rounded-2xl bg-white p-4 ring-1 ring-inset ring-zinc-200/80">
            <div className="text-sm font-bold">Tugaskan job</div>
            <p className="mt-1 text-xs leading-5 text-zinc-500">Pilih freelancer. Freelancer memulai pekerjaan dari status Antre.</p>
            <div className="mt-3 grid gap-2 sm:grid-cols-[minmax(12rem,0.8fr)_minmax(16rem,1.4fr)_auto]">
              <Select
                ariaLabel="Pilih freelance penerima" className="w-full sm:w-64"
                value={assignTo} onChange={setAssignTo} placeholder="— pilih freelance —"
                options={freelances.map((p) => {
                  const online = isOnline(p.lastSeen, now);
                  const ready = online && p.availabilityStatus === "ready";
                  const pending = online && p.availabilityStatus === "pending";
                  const n = activeJobCount(data.jobs, p.id);
                  const eligible = p.isActive && p.registrationStatus === "approved" && ready && n < data.maxActive;
                  return {
                    value: p.id,
                    label: p.name,
                    hint: `${online ? (ready ? "● online · siap menerima" : pending ? "● online · belum check-in" : "● online · tidak siap") : "○ offline"} • ${n}/${data.maxActive} aktif${!p.isActive || p.registrationStatus !== "approved" ? " · belum aktif" : ""}`,
                    disabled: !eligible,
                  };
                })}
              />
              <input aria-label="Alasan pengalihan" className="input min-w-0 px-3 py-1.5 text-sm" placeholder="Alasan wajib saat mengalihkan pekerjaan" value={assignmentReason} onChange={(e) => setAssignmentReason(e.target.value)} />
              <button
                className="btn-primary rounded-xl px-4 py-1.5 text-sm font-semibold text-white" disabled={busy}
                onClick={() => {
                  if (!assignTo) { onToast("Pilih penerima"); return; }
                  run(ctx.assignJob(job.id, assignTo, assignmentReason), "Penugasan tersimpan");
                }}
              >
                Tugaskan
              </button>
            </div>
          </div>
        )}

        {transitions.length > 0 && (
          <div className="rounded-2xl bg-white p-4 ring-1 ring-inset ring-zinc-200/80">
            <div className="text-sm font-bold">Perubahan status</div>
            <p className="mt-1 text-xs leading-5 text-zinc-500">Aksi yang tersedia mengikuti status job dan peran akun Anda.</p>
            <div className="mt-3 grid gap-2 sm:grid-cols-2">
            {transitions.filter((t) => t.to !== "ACC" && t.to !== "Revisi" && t.to !== "MintaACC").map((t) => (
              <button
                key={t.to} disabled={busy} className="btn-primary w-full rounded-xl px-3.5 py-2.5 text-sm font-bold text-white disabled:opacity-50"
                onClick={() => run(ctx.transition(job.id, t.to), `Status → ${t.to}`)}
              >
                {t.label}
              </button>
            ))}
            </div>
          </div>
        )}
        {isAdmin && job.status === "Finished" && (
          <div className="rounded-2xl bg-white p-4 ring-1 ring-inset ring-zinc-200/80">
            <div className="text-sm font-bold">Pekerjaan lanjutan</div>
              <p className="mt-1 text-xs leading-5 text-zinc-500">Job yang sudah selesai tidak dapat diedit. Buat job baru untuk koreksi.</p>
            <button
              className="btn-ghost mt-3 w-full rounded-xl px-3.5 py-2 text-sm font-semibold" disabled={busy}
              onClick={() => {
                setBusy(true);
                void ctx.createJob({
                  tim: job.tim, jenis: job.jenis, qty: job.qty, fee: job.fee,
                  priority: job.priority, brief: job.brief,
                  ref: `Lanjutan koreksi dari ${formatJobCode(job.id)}`,
                }).then((r) => {
                  setBusy(false);
                  onToast(r.ok ? `Job lanjutan ${formatJobCode(r.id as string)} dibuat (Belum Ditugaskan)` : (r.error ?? "Gagal"));
                });
              }}
            >
              + Buat job lanjutan koreksi
            </button>
          </div>
        )}

        {isAdmin && !["Finished", "Dibatalkan"].includes(job.status) && (
          <div className="rounded-2xl border border-rose-200 bg-rose-50/70 p-4">
            <div className="text-sm font-bold text-rose-950">Batalkan atau hapus job</div>
            <p className="mt-1 text-xs leading-5 text-rose-800/80">Pembatalan mengubah status dan menyimpan alasan. Penghapusan permanen hanya tersedia untuk job yang belum ditugaskan.</p>
            <div className="mt-3 flex flex-col gap-2 sm:flex-row">
              <input aria-label="Alasan pembatalan" className="input min-w-0 flex-1 px-3 py-1.5 text-sm" placeholder="Alasan pembatalan (wajib)" value={cancellationReason} onChange={(e) => setCancellationReason(e.target.value)} />
              <button
                className="btn-danger shrink-0 rounded-xl px-4 py-1.5 text-sm font-semibold text-white" disabled={busy}
                onClick={() => { if (!confirm(`Batalkan ${formatJobCode(job.id)}?`)) return; run(ctx.cancelJob(job.id, cancellationReason), "Job Dibatalkan"); }}
              >
                Batalkan job
              </button>
            </div>
            {job.status === "Belum Ditugaskan" && (
              <button
                className="btn-ghost mt-2 rounded-xl px-3.5 py-1.5 text-sm font-semibold text-rose-800" disabled={busy}
                onClick={() => {
                  if (!confirm("Hapus permanen? Hanya untuk Belum Ditugaskan tanpa aktivitas/file.")) return;
                  setBusy(true);
                  void ctx.deleteJobPermanent(job.id).then((r) => {
                    setBusy(false);
                    if (r.ok) onClose();
                    onToast(r.ok ? "Job dihapus" : (r.error ?? "Gagal"));
                  });
                }}
              >
                Hapus permanen
              </button>
            )}
          </div>
        )}
        </div>
        </section>

        <section id="job-files" role="tabpanel" aria-labelledby="job-files-tab" tabIndex={0} hidden={activeSection !== "job-files"} className="glass-card-gradient overflow-hidden p-0">
        <SectionHeading title="Preview dan file asli" description="Kirim gambar untuk ditinjau Admin, lalu serahkan file CDR setelah disetujui." />
        <div className="space-y-4 p-3.5 sm:p-5">
                {/* File privat di R2 dikirim melalui tautan bertanda tangan. */}
        <FileSection job={job} onToast={onToast} busy={busy} setBusy={setBusy} />
        {/* Submission */}
        <SubmissionSection job={job} onToast={onToast} busy={busy} setBusy={setBusy} reason={reviewReason} setReason={setReviewReason} now={now} />
        </div>
        </section>

        <section id="job-activity" role="tabpanel" aria-labelledby="job-activity-tab" tabIndex={0} hidden={activeSection !== "job-activity"} className="glass-card-gradient overflow-hidden p-0">
        <SectionHeading title="Aktivitas" description="Siapkan komunikasi dan lihat riwayat perubahan job." />
        <div className="p-3.5 sm:p-5">
        <WaDraft job={job} />

        <div className="mt-4 rounded-2xl bg-white p-4 ring-1 ring-inset ring-zinc-200/80">
          <div className="flex items-center justify-between gap-3">
            <div>
              <div className="text-sm font-bold text-zinc-900">Riwayat aktivitas</div>
              <p className="mt-0.5 text-xs text-zinc-500">Perubahan job yang sudah tercatat.</p>
            </div>
            <span className="rounded-lg bg-zinc-100 px-2 py-1 text-[11px] font-semibold tabular-nums text-zinc-600">{jobEvents.length} aktivitas</span>
          </div>
          {jobEvents.length === 0 && (
            <div className="mt-3 rounded-xl border border-dashed border-zinc-200 bg-zinc-50/70 px-3 py-5 text-center text-xs text-zinc-500">Belum ada aktivitas untuk job ini.</div>
          )}
          <ul className="relative mt-4 space-y-3 border-l-2 border-indigo-100 pl-4">
            {jobEvents.map((e) => (
              <li key={e.id} className="relative text-xs text-zinc-600">
                <span className="absolute -left-[22px] top-1 h-2.5 w-2.5 rounded-full bg-gradient-to-br from-indigo-500 to-violet-500 ring-2 ring-white" aria-hidden />
                <span className="font-semibold text-zinc-800">{formatWIB(e.createdAt)}</span> • {e.actorName}
                <span className="ml-1.5 rounded-md bg-zinc-100 px-1.5 py-0.5 text-[11px] text-zinc-600">{activityLabel[e.type] ?? e.type.replaceAll("_", " ")}</span>
                {(e.fromStatus || e.toStatus) && <span> ({e.fromStatus ?? ""} → {e.toStatus ?? ""})</span>}
                {e.reason && <span className="mt-0.5 block italic text-zinc-500">“{e.reason}”</span>}
              </li>
            ))}
          </ul>
        </div>
        </div>
        </section>
        </div>
        </div>
      </section>
    </div>
  );
}

function FileSection({ job, onToast, busy, setBusy }: { job: Job; onToast: Toast; busy: boolean; setBusy: (v: boolean) => void }) {
  const ctx = useReadyStore();
  const files = ctx.data.files.filter((f) => f.jobId === job.id);
  const referenceFiles = files.filter((f) => f.fileRole === "reference");
  const previewFiles = files.filter((f) => f.fileRole === "preview");
  const sourceFiles = files.filter((f) => f.fileRole === "source");
  const legacyResultFiles = files.filter((f) => f.fileRole === "result");
  const isAdmin = hasOperationsAccess(ctx.currentProfile.role);
  const isAssignedFreelancer = ctx.currentProfile.role === "freelance" && job.assigneeId === ctx.currentProfile.id;
  const [submitSel, setSubmitSel] = useState<string[]>([]);
  const [note, setNote] = useState("");
  const [picked, setPicked] = useState<{ role: "reference" | "preview" | "source"; name: string } | null>(null);
  const [previewFile, setPreviewFile] = useState<(typeof files)[number] | null>(null);

  const doUpload = (file: File | undefined, role: "reference" | "preview" | "source") => {
    if (!file) return;
    const kind = validateFileKind(file.name);
    if (role === "preview" && !["PNG", "JPEG", "SVG"].includes(kind ?? "")) { onToast("Preview harus berupa gambar PNG, JPG, atau SVG"); return; }
    if (role === "source" && kind !== "CDR") { onToast("File asli harus berformat CDR"); return; }
    setBusy(true);
    void ctx.uploadFile(job.id, file, role).then((r) => {
      setBusy(false);
      setPicked(null);
      onToast(r.ok ? role === "reference" ? "File referensi terunggah" : role === "preview" ? "Gambar preview terunggah" : "File asli CDR terunggah" : (r.error ?? "Gagal"));
      const el = document.getElementById(`up-${role}-${job.id}`) as HTMLInputElement | null;
      if (el) el.value = "";
    });
  };

  const doUploadPreviews = (selected: File[]) => {
    if (selected.length === 0) return;
    const invalid = selected.find((file) => !["PNG", "JPEG", "SVG"].includes(validateFileKind(file.name) ?? ""));
    if (invalid) { onToast(`${invalid.name}: preview harus PNG, JPG, atau SVG`); return; }
    setBusy(true);
    void (async () => {
      let uploaded = 0;
      let error: string | undefined;
      for (const file of selected) {
        const result = await ctx.uploadFile(job.id, file, "preview");
        if (!result.ok) { error = result.error ?? "Gagal"; break; }
        uploaded += 1;
      }
      setBusy(false);
      setPicked(null);
      onToast(uploaded === selected.length ? `${uploaded} gambar preview terunggah` : `${uploaded}/${selected.length} gambar terunggah · ${error}`);
      const el = document.getElementById(`up-preview-${job.id}`) as HTMLInputElement | null;
      if (el) el.value = "";
    })();
  };

  const renderFileList = (items: typeof files, emptyMessage: string) => (
    <>
      {items.length === 0 && <div className="mt-1 text-xs text-zinc-500">{emptyMessage}</div>}
      <ul className="mt-2 space-y-1.5 text-sm">
        {items.map((f) => (
          <li key={f.id} className="tile-soft px-2.5 py-2">
            <div className="min-w-0 flex-1 truncate font-mono text-xs font-semibold" title={f.name}>{f.name}</div>
            <div className="mt-1 flex flex-wrap items-center gap-1.5">
              <span className="rounded-md bg-indigo-50 px-1.5 py-0.5 text-[11px] font-bold text-indigo-700 ring-1 ring-inset ring-indigo-200">{f.fileKind}</span>
              <span className="text-[11px] tabular-nums text-zinc-500">{(f.sizeBytes / 1048576).toFixed(1)} MB</span>
              {f.lockedSubmissionId && <span className="rounded-md bg-amber-50 px-1.5 py-0.5 text-[11px] font-bold text-amber-800 ring-1 ring-inset ring-amber-200">terkunci</span>}
              <span className="ml-auto flex gap-1.5">
                <button
                  className="btn-ghost rounded-lg px-2 py-0.5 text-xs font-semibold"
                  onClick={() => setPreviewFile(f)}
                >
                  Pratinjau
                </button>
                {!f.lockedSubmissionId && isAdmin && job.status !== "Finished" && (
                  <button
                    className="rounded-lg px-2 py-0.5 text-xs font-semibold text-rose-600 hover:bg-rose-50" disabled={busy}
                    onClick={() => {
                      setBusy(true);
                      void ctx.deleteFile(f.id).then((r) => {
                        setBusy(false);
                        onToast(r.ok ? "File dihapus" : (r.error ?? "Gagal"));
                      });
                    }}
                  >
                    hapus
                  </button>
                )}
              </span>
            </div>
          </li>
        ))}
      </ul>
    </>
  );

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2.5 rounded-xl bg-gradient-to-r from-indigo-50 to-violet-50 px-3 py-2.5 text-xs text-indigo-900 ring-1 ring-inset ring-indigo-100">
        <span className="grid size-7 shrink-0 place-items-center rounded-lg bg-white text-indigo-600 ring-1 ring-inset ring-indigo-100" aria-hidden>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        </span>
        <span><strong className="font-bold">Batas penyimpanan</strong><span className="text-indigo-800/80"> · Maks. 1 GiB per file dan 10 GiB per job.</span></span>
      </div>
      {(referenceFiles.length > 0 || isAdmin) && (
        <section className="rounded-2xl bg-white p-3 shadow-sm ring-1 ring-inset ring-zinc-200/80">
          <div className="flex items-center justify-between gap-2">
            <div className="text-sm font-bold text-zinc-900">File referensi <span className="font-medium text-zinc-500">(panduan kerja)</span></div>
            <span className="shrink-0 rounded-lg bg-zinc-100 px-2 py-1 text-[10px] font-semibold tabular-nums text-zinc-500">{referenceFiles.length} file</span>
          </div>
          {renderFileList(referenceFiles, "Belum ada file referensi.")}
          {isAdmin && !["Preview", "ACC", "Finished", "Dibatalkan"].includes(job.status) && (
            <div className="mt-2 flex flex-wrap items-center gap-2">
              <label className={`btn-ghost cursor-pointer rounded-xl px-3.5 py-1.5 text-xs font-bold ${busy ? "pointer-events-none opacity-60" : ""}`}>
                {busy && picked?.role === "reference" ? "Mengunggah…" : "+ Tambah referensi"}
                <input
                  id={`up-reference-${job.id}`} type="file" accept={ACCEPTED_FILE_EXTENSIONS}
                  className="hidden" disabled={busy}
                  onChange={(e) => {
                    const file = e.target.files?.[0];
                    setPicked(file ? { role: "reference", name: file.name } : null);
                    doUpload(file, "reference");
                  }}
                />
              </label>
              <span className="min-w-0 flex-1 truncate text-xs text-zinc-500">{picked?.role === "reference" ? picked.name : "Tambahkan brief visual atau dokumen pendukung."}</span>
            </div>
          )}
        </section>
      )}
      {(previewFiles.length > 0 || isAssignedFreelancer && ["Dikerjakan", "Revisi"].includes(job.status)) && (
      <section className="rounded-2xl bg-white p-3 shadow-sm ring-1 ring-inset ring-zinc-200/80">
        <div className="flex items-center justify-between gap-2">
          <div>
            <div className="text-sm font-bold text-zinc-900">Gambar preview</div>
            <p className="mt-0.5 text-xs text-zinc-500">Kirim beberapa gambar untuk diperiksa Admin sebelum file asli CDR.</p>
          </div>
          <span className="shrink-0 rounded-lg bg-zinc-100 px-2 py-1 text-[10px] font-semibold tabular-nums text-zinc-500">{previewFiles.length} file</span>
        </div>
        {renderFileList(previewFiles, "Belum ada gambar preview.")}
        {isAssignedFreelancer && ["Dikerjakan", "Revisi"].includes(job.status) && (
          <div className="mt-2.5 flex flex-wrap items-center gap-2">
            <label className={`btn-ghost cursor-pointer rounded-xl px-3.5 py-1.5 text-xs font-bold ${busy ? "pointer-events-none opacity-60" : ""}`}>
              {busy && picked?.role === "preview" ? "Mengunggah…" : "+ Tambah gambar preview"}
              <input id={`up-preview-${job.id}`} type="file" multiple accept=".png,.jpg,.jpeg,.svg,image/png,image/jpeg,image/svg+xml" className="hidden" disabled={busy} onChange={(e) => {
                const selected = Array.from(e.target.files ?? []);
                setPicked(selected.length ? { role: "preview", name: `${selected.length} gambar` } : null);
                doUploadPreviews(selected);
              }} />
            </label>
            <span className="text-xs text-zinc-500">PNG, JPG, atau SVG.</span>
          </div>
        )}
      </section>
      )}
      {(sourceFiles.length > 0 || isAssignedFreelancer && job.status === "ACC") && (
        <section className="rounded-2xl border border-emerald-200/80 bg-gradient-to-br from-white to-emerald-50/50 p-3 shadow-sm">
          <div className="flex items-center justify-between gap-2">
            <div>
              <div className="text-sm font-bold text-zinc-900">File asli CDR</div>
              <p className="mt-0.5 text-xs text-zinc-500">Tahap ini terbuka setelah preview disetujui Admin.</p>
            </div>
            <span className="shrink-0 rounded-lg bg-emerald-50 px-2 py-1 text-[10px] font-semibold tabular-nums text-emerald-800 ring-1 ring-inset ring-emerald-200">{sourceFiles.length} file</span>
          </div>
          {renderFileList(sourceFiles, "Belum ada file asli CDR.")}
          {isAssignedFreelancer && job.status === "ACC" && (
            <div className="mt-2.5 flex flex-wrap items-center gap-2">
              <label className={`btn-ghost cursor-pointer rounded-xl px-3.5 py-1.5 text-xs font-bold ${busy ? "pointer-events-none opacity-60" : ""}`}>
                {busy && picked?.role === "source" ? "Mengunggah…" : "+ Pilih file asli CDR"}
                <input id={`up-source-${job.id}`} type="file" accept=".cdr,application/octet-stream" className="hidden" disabled={busy} onChange={(e) => {
                  const file = e.target.files?.[0];
                  setPicked(file ? { role: "source", name: file.name } : null);
                  doUpload(file, "source");
                }} />
              </label>
              <span className="text-xs text-zinc-500">File CDR asli hasil final.</span>
              <button className="btn-success ml-auto rounded-xl px-3.5 py-2 text-xs font-bold text-white disabled:opacity-50" disabled={busy || !sourceFiles.some((file) => file.uploadedBy === ctx.currentProfile.id && file.fileKind === "CDR")} onClick={() => {
                setBusy(true);
                void ctx.finishJob(job.id).then((r) => {
                  setBusy(false);
                  onToast(r.ok ? "File asli dikirim — job Finished" : (r.error ?? "Gagal"));
                });
              }}>
                Kirim file asli & tandai Finished
              </button>
            </div>
          )}
          {isAssignedFreelancer && job.status === "ACC" && !sourceFiles.some((file) => file.uploadedBy === ctx.currentProfile.id && file.fileKind === "CDR") && <p className="mt-2 text-xs text-amber-800">Unggah minimal satu file CDR sebelum menyelesaikan job.</p>}
          {job.status === "Finished" && <p className="mt-2 text-xs font-semibold text-emerald-800">File asli sudah dikirim dan job telah selesai.</p>}
        </section>
      )}
      {legacyResultFiles.length > 0 && (
        <section className="rounded-2xl bg-white p-3 shadow-sm ring-1 ring-inset ring-zinc-200/80">
          <div className="text-sm font-bold text-zinc-900">File hasil lama</div>
          <p className="mt-0.5 text-xs text-zinc-500">File yang diunggah sebelum alur preview diterapkan.</p>
          {renderFileList(legacyResultFiles, "Belum ada file hasil lama.")}
        </section>
      )}
      <PreviewSubmissionPicker
        job={job} onToast={onToast} busy={busy} setBusy={setBusy} note={note} setNote={setNote}
        submitSel={submitSel} setSubmitSel={setSubmitSel}
      />
      {previewFile && (
        <div
          className="fixed inset-0 z-[60] flex items-center justify-center bg-slate-950/75 p-3 backdrop-blur-sm sm:p-6"
          role="presentation"
          onMouseDown={(event) => { if (event.target === event.currentTarget) setPreviewFile(null); }}
        >
          <section className="flex h-[calc(100dvh-1.5rem)] w-full max-w-7xl flex-col overflow-hidden rounded-2xl border border-white/70 border-t-2 border-t-indigo-500 bg-white shadow-[0_32px_100px_-24px_rgba(15,23,42,0.65)] sm:h-[88dvh] sm:rounded-3xl" role="dialog" aria-modal="true" aria-labelledby={`preview-title-${previewFile.id}`}>
            <header className="flex shrink-0 items-center justify-between gap-3 border-b border-zinc-200/80 bg-white px-3.5 py-3 sm:px-5">
              <div className="flex min-w-0 items-center gap-3">
                <div className="grid size-10 shrink-0 place-items-center rounded-xl bg-gradient-to-br from-indigo-600 to-violet-600 text-white shadow-md shadow-indigo-500/20" aria-hidden>
                  <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" /><path d="M14 2v6h6M8 13h8M8 17h8" /></svg>
                </div>
                <div className="min-w-0">
                  <div className="flex min-w-0 items-center gap-2">
                    <h2 id={`preview-title-${previewFile.id}`} className="truncate text-sm font-bold text-zinc-900 sm:text-base">{previewFile.name}</h2>
                    <span className="hidden shrink-0 rounded-full bg-indigo-50 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-indigo-700 sm:inline-flex">{previewFile.fileKind}</span>
                  </div>
                  <p className="mt-0.5 truncate text-[11px] text-zinc-500 sm:text-xs">Pratinjau file <span className="hidden sm:inline">• tersimpan di ruang kerja privat</span></p>
                </div>
              </div>
              <button aria-label="Tutup pratinjau" className="btn-ghost inline-flex shrink-0 items-center gap-1.5 rounded-xl px-2.5 py-2 text-xs font-semibold sm:px-3" onClick={() => setPreviewFile(null)}>
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" aria-hidden><path d="m18 6-12 12M6 6l12 12" /></svg>
                <span className="hidden sm:inline">Tutup</span>
              </button>
            </header>
            <div className="min-h-0 flex-1 bg-gradient-to-br from-zinc-100 via-slate-100 to-indigo-50/70 p-1.5 sm:p-3">
              <iframe
                key={previewFile.id}
                src={`/api/job-files/${encodeURIComponent(previewFile.id)}/preview${["PNG", "JPEG", "SVG"].includes(previewFile.fileKind) ? "" : "#toolbar=0&navpanes=0&view=FitH"}`}
                title={`Pratinjau ${previewFile.name}`}
                className="h-full min-h-0 w-full rounded-xl border border-zinc-200/80 bg-white shadow-sm"
              />
            </div>
            <footer className="flex shrink-0 flex-col items-stretch justify-between gap-2.5 border-t border-zinc-200/80 bg-white px-3.5 py-3 sm:flex-row sm:items-center sm:px-5">
              <span className="text-[11px] leading-relaxed text-zinc-500 sm:text-xs">Gulir dokumen untuk melihat halaman lainnya. Untuk fitur lengkap, buka file asli.</span>
              <button
                className="btn-primary inline-flex shrink-0 items-center justify-center gap-2 rounded-xl px-4 py-2 text-xs font-bold text-white"
                onClick={() => {
                  if (!previewFile.path) { onToast("Path file tidak tersedia"); return; }
                  void ctx.fileUrl(previewFile.path).then((url) => {
                    if (url) window.open(url, "_blank", "noopener,noreferrer");
                    else onToast("Gagal membuat tautan file");
                  });
                }}
              >
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d="M14 3h7v7M10 14 21 3" /><path d="M21 14v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5" /></svg>
                Buka file asli
              </button>
            </footer>
          </section>
        </div>
      )}
    </div>
  );
}

function PreviewSubmissionPicker({ job, onToast, busy, setBusy, note, setNote, submitSel, setSubmitSel }: {
  job: Job; onToast: Toast; busy: boolean; setBusy: (v: boolean) => void;
  note: string; setNote: (v: string) => void; submitSel: string[]; setSubmitSel: (v: string[]) => void;
}) {
  const ctx = useReadyStore();
  const files = ctx.data.files.filter((f) => f.jobId === job.id && f.fileRole === "preview" && !f.lockedSubmissionId);
  if (!["Dikerjakan", "Revisi"].includes(job.status)) return null;
  if (ctx.currentProfile.role !== "freelance" || job.assigneeId !== ctx.currentProfile.id) return null;
  return (
    <div className="rounded-xl bg-gradient-to-br from-violet-50 to-indigo-50 p-2.5 ring-1 ring-inset ring-violet-200">
      <div className="text-xs font-bold text-violet-950">Ajukan preview ke Admin (pilih ≥1 gambar)</div>
      {files.length === 0 && <div className="text-xs text-zinc-500">Unggah gambar preview PNG, JPG, atau SVG terlebih dahulu.</div>}
      {files.map((f) => (
        <label key={f.id} className="flex items-center gap-1 text-xs">
          <input
            type="checkbox" checked={submitSel.includes(f.id)}
            onChange={(e) => setSubmitSel(e.target.checked ? [...submitSel, f.id] : submitSel.filter((x) => x !== f.id))}
          />
          {f.name}
        </label>
      ))}
      <div className="mt-1 flex gap-1">
        <input className="input flex-1 px-2.5 py-1 text-xs" placeholder="Catatan" value={note} onChange={(e) => setNote(e.target.value)} />
        <button
          className="btn-violet rounded-lg px-2.5 py-1 text-xs font-semibold text-white" disabled={busy}
          onClick={() => {
            if (submitSel.length < 1) { onToast("Pilih ≥1 file"); return; }
            setBusy(true);
            void ctx.submitPreview(job.id, submitSel, note).then((r) => {
              setBusy(false);
              if (r.ok) { setSubmitSel([]); setNote(""); }
              onToast(r.ok ? "Preview diajukan untuk review Admin" : (r.error ?? "Gagal"));
            });
          }}
        >
          Ajukan Preview
        </button>
      </div>
    </div>
  );
}

function SubmissionSection({ job, onToast, busy, setBusy, reason, setReason, now }: {
  job: Job; onToast: Toast; busy: boolean; setBusy: (v: boolean) => void;
  reason: string; setReason: (v: string) => void; now: number;
}) {
  const ctx = useReadyStore();
  const subs = ctx.data.submissions.filter((s) => s.jobId === job.id).sort((a, b) => a.version - b.version);
  if (subs.length === 0) return null;
  const isAdmin = hasOperationsAccess(ctx.currentProfile.role);
  const pending = subs.find((s) => s.id === job.currentSubmissionId && s.decision === "pending" && s.submissionType === "preview" && job.status === "Preview");
  const waitH = pending ? (now - new Date(pending.submittedAt).getTime()) / 3600_000 : 0;
  return (
    <div className="rounded-2xl border border-violet-200/80 bg-gradient-to-br from-violet-50/80 to-indigo-50/80 p-3.5 shadow-sm">
      <div className="flex items-center justify-between gap-3">
        <div>
          <div className="text-sm font-bold text-violet-950">Review preview</div>
          <p className="mt-0.5 text-xs text-violet-900/65">Admin menyetujui gambar atau meminta freelancer memperbaikinya.</p>
        </div>
        <span className="rounded-lg bg-white/80 px-2 py-1 text-[10px] font-semibold tabular-nums text-violet-700 ring-1 ring-inset ring-violet-200">{subs.length} versi</span>
      </div>
      {pending && (
        <div className={`mt-1.5 rounded-xl px-2.5 py-1.5 text-xs font-medium ring-1 ring-inset ${waitH >= 24 ? "bg-amber-50 text-amber-900 ring-amber-200" : "bg-white/70 text-zinc-600 ring-zinc-200/80"}`}>
          Menunggu review {waitH < 1 ? "<1" : Math.floor(waitH)} jam (target 1×24 jam){waitH >= 24 ? " — lewat target" : ""}
        </div>
      )}
      <ul className="mt-3 space-y-2 text-sm">
        {subs.map((s) => (
          <li key={s.id} className={`rounded-xl p-3 ${s.id === job.currentSubmissionId ? "border border-violet-300 bg-white shadow-sm" : "border border-zinc-200/80 bg-white/70"}`}>
            <div className="flex flex-wrap items-center gap-1.5">
              <span className="rounded-md bg-violet-100 px-2 py-1 text-[10px] font-bold text-violet-800">{s.submissionType === "preview" ? "Preview" : "Submission lama"} · versi {s.version}</span>
              <span className="rounded-md bg-zinc-100 px-2 py-1 text-[10px] font-semibold text-zinc-700">{s.submissionType === "legacy" && s.decision === "pending" && s.id !== job.currentSubmissionId ? "Alur lama · tidak aktif" : s.decision === "pending" ? "Menunggu review" : s.decision === "approved" ? "Disetujui" : "Revisi diminta"}</span>
              <span className="text-[11px] text-zinc-500">{s.fileIds.length} file</span>
              <span className="ml-auto text-[11px] tabular-nums text-zinc-500">{formatWIB(s.submittedAt)}</span>
            </div>
            {s.note && <p className="mt-2 text-xs text-zinc-600">Catatan freelancer: {s.note}</p>}
            {s.reviewNote && <p className="mt-2 border-t border-zinc-100 pt-2 text-xs text-zinc-600">Catatan review: {s.reviewNote}</p>}
            {isAdmin && job.status === "Preview" && s.submissionType === "preview" && s.decision === "pending" && s.id === job.currentSubmissionId && (
              <div className="mt-1 flex gap-2">
                <button
                  className="btn-success rounded-lg px-2.5 py-1 text-xs font-semibold text-white" disabled={busy}
                  onClick={() => {
                    setBusy(true);
                    void ctx.transition(job.id, "ACC", { submissionId: s.id }).then((r) => {
                      setBusy(false);
                      onToast(r.ok ? "Preview di-ACC — freelancer dapat mengirim file asli CDR" : (r.error ?? "Gagal"));
                    });
                  }}
                >
                  Setujui preview
                </button>
                <span className="flex flex-1 gap-1">
                  <input className="input flex-1 px-2.5 py-1 text-xs" placeholder="Alasan revisi (wajib)" value={reason} onChange={(e) => setReason(e.target.value)} />
                  <button
                    className="btn-ghost rounded-lg px-2.5 py-1 text-xs font-semibold" disabled={busy}
                    onClick={() => {
                      setBusy(true);
                      void ctx.transition(job.id, "Revisi", { submissionId: s.id, reason }).then((r) => {
                        setBusy(false);
                      onToast(r.ok ? "Revisi diminta — job dikembalikan ke freelancer" : (r.error ?? "Gagal"));
                      });
                    }}
                  >
                    Revisi
                  </button>
                </span>
              </div>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}

function WaDraft({ job }: { job: Job }) {
  const [waText, setWaText] = useState("");
  return (
    <div className="mt-4 rounded-2xl border border-emerald-200/70 bg-gradient-to-br from-white to-emerald-50/50 p-4 shadow-sm">
      <div className="flex items-center justify-between gap-3">
        <div>
          <div className="text-sm font-bold text-zinc-900">Draft WhatsApp</div>
          <p className="mt-0.5 text-xs text-zinc-500">Siapkan pesan untuk tim terkait job ini.</p>
        </div>
        <span className="rounded-lg bg-white/80 px-2 py-1 text-[10px] font-semibold text-emerald-700 ring-1 ring-inset ring-emerald-200">Draft</span>
      </div>
      <div className="mt-3 grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
        <input aria-label="Isi pesan draft WhatsApp" className="input min-w-0 px-3 py-2 text-sm" placeholder="Tulis pesan untuk dikirim…" value={waText} onChange={(e) => setWaText(e.target.value)} />
        <a
          className="btn-primary inline-flex items-center justify-center rounded-xl px-4 py-2 text-sm font-semibold text-white" target="_blank" rel="noreferrer"
          href={`https://wa.me/?text=${encodeURIComponent(`[${formatJobCode(job.id)} ${job.tim}] ${waText || job.brief}`)}`}
        >
          Buka draft WA
        </a>
      </div>
    </div>
  );
}
