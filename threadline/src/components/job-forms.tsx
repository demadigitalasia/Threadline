"use client";

import { useState } from "react";
import { useReadyStore } from "@/lib/store-context";
import {
  ACCEPTED_FILE_EXTENSIONS, formatJobCode, MAX_FILE_BYTES, MAX_JOB_BYTES,
  type JobType, validateFileKind,
} from "@/lib/domain";
import { DatePicker } from "./date-picker";
import { Select, type Toast } from "./threadline-ui";

export function CreateJob({ onClose, onToast }: { onClose: () => void; onToast: Toast }) {
  const { createJob, uploadFile } = useReadyStore();
  const [tim, setTim] = useState("");
  const [jenis, setJenis] = useState<JobType>("Fullprint");
  const [qty, setQty] = useState(20);
  const [fee, setFee] = useState(1000000);
  const [deadline, setDeadline] = useState("");
  const [priority, setPriority] = useState<"normal" | "express">("normal");
  const [brief, setBrief] = useState("");
  const [referenceFiles, setReferenceFiles] = useState<File[]>([]);
  const [busy, setBusy] = useState(false);

  const feePreview = `Rp${Number(fee || 0).toLocaleString("id-ID")}`;

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-indigo-950/55 p-4 backdrop-blur-sm">
      <form
        className="max-h-[90vh] w-full max-w-lg overflow-y-auto rounded-3xl border border-white/60 bg-white p-0 shadow-[0_32px_80px_-16px_rgba(30,27,75,0.55)]"
        onSubmit={(e) => {
          e.preventDefault();
          const unsupported = referenceFiles.find((file) => !validateFileKind(file.name));
          if (unsupported) { onToast(`Format ${unsupported.name} tidak didukung`); return; }
          const oversized = referenceFiles.find((file) => file.size > MAX_FILE_BYTES);
          if (oversized) { onToast(`${oversized.name}: maksimal 1 GiB per file`); return; }
          const referenceBytes = referenceFiles.reduce((total, file) => total + file.size, 0);
          if (referenceBytes > MAX_JOB_BYTES) { onToast("Total file referensi melebihi 10 GiB per job"); return; }
          setBusy(true);
          void createJob({
            tim, jenis, qty: Number(qty), fee: Number(fee),
            deadline: deadline ? new Date(deadline).toISOString() : undefined,
            priority, brief,
          }).then(async (r) => {
            if (!r.ok || !r.id) { setBusy(false); onToast(r.error ?? "Gagal membuat job"); return; }
            let failedUploads = 0;
            for (const file of referenceFiles) {
              const uploaded = await uploadFile(r.id, file, "reference");
              if (!uploaded.ok) failedUploads += 1;
            }
            setBusy(false);
            const jobCode = formatJobCode(r.id);
            onToast(failedUploads
              ? `Job ${jobCode} dibuat; ${failedUploads} file referensi gagal diunggah. Tambahkan dari detail job.`
              : `Job ${jobCode} masuk Belum Ditugaskan`);
            onClose();
          });
        }}
      >
        <div className="rounded-t-3xl bg-gradient-to-r from-indigo-600 via-violet-600 to-fuchsia-500 px-5 py-4 text-white sm:px-6">
          <div className="flex items-center justify-between gap-2">
            <div>
              <div className="text-base font-extrabold tracking-tight">+ Buat job</div>
              <div className="mt-0.5 text-xs text-white/75">Masuk antrean Belum Ditugaskan • belum memakai kapasitas</div>
            </div>
            <button type="button" aria-label="Tutup" onClick={onClose} disabled={busy} className="rounded-lg p-1.5 text-white/80 hover:bg-white/15 hover:text-white disabled:opacity-50">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" aria-hidden><path d="M18 6 6 18M6 6l12 12" /></svg>
            </button>
          </div>
        </div>
        <div className="space-y-3 p-5 sm:p-6">
        <div>
          <label htmlFor="cj-tim" className="mb-1 block text-xs font-bold text-zinc-700">Nama tim</label>
          <input id="cj-tim" className="input w-full px-3 py-2 text-sm" placeholder="cth. Tim Garuda FC" value={tim} onChange={(e) => setTim(e.target.value)} required />
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div>
            <span className="mb-1 block text-xs font-bold text-zinc-700">Jenis</span>
            <Select
              ariaLabel="Jenis job" value={jenis} onChange={(v) => setJenis(v as JobType)}
              options={[
                { value: "Fullprint", label: "Fullprint" },
                { value: "Printing Depan Saja", label: "Printing Depan Saja" },
                { value: "Jersey + Celana", label: "Jersey + Celana" },
                { value: "Jaket", label: "Jaket" },
              ]}
            />
          </div>
          <div>
            <span className="mb-1 block text-xs font-bold text-zinc-700">Prioritas</span>
            <Select
              ariaLabel="Prioritas job" value={priority} onChange={(v) => setPriority(v as "normal" | "express")}
              options={[
                { value: "normal", label: "Normal", hint: "Antrean standar" },
                { value: "express", label: "Express", hint: "Paling atas + notifikasi" },
              ]}
            />
          </div>
          <div>
            <label htmlFor="cj-qty" className="mb-1 block text-xs font-bold text-zinc-700">Qty (pcs)</label>
            <input id="cj-qty" className="input w-full px-3 py-2 text-sm tabular-nums" type="number" min={1} value={qty} onChange={(e) => setQty(Number(e.target.value))} placeholder="20" />
          </div>
          <div>
            <label htmlFor="cj-fee" className="mb-1 block text-xs font-bold text-zinc-700">Fee (Rp, bulat)</label>
            <input id="cj-fee" className="input w-full px-3 py-2 text-sm tabular-nums" type="number" min={0} step={1000} value={fee} onChange={(e) => setFee(Number(e.target.value))} placeholder="1000000" />
            <p className="mt-1 text-[11px] tabular-nums text-indigo-600">≈ {feePreview}</p>
          </div>
        </div>
        <div>
          <label htmlFor="cj-dl" className="mb-1 block text-xs font-bold text-zinc-700">Deadline <span className="font-medium text-zinc-400">(mengikuti zona waktu perangkat — disimpan timestamp)</span></label>
          <DatePicker id="cj-dl" ariaLabel="Pilih deadline job" withTime value={deadline} onChange={setDeadline} />
        </div>
        <div>
          <label htmlFor="cj-brief" className="mb-1 block text-xs font-bold text-zinc-700">Brief</label>
          <textarea id="cj-brief" className="input w-full px-3 py-2 text-sm" placeholder="Bahan, warna, nama & nomor punggung…" value={brief} onChange={(e) => setBrief(e.target.value)} rows={3} />
        </div>
        <div>
          <label htmlFor="cj-reference-files" className="mb-1 block text-xs font-bold text-zinc-700">File referensi <span className="font-medium text-zinc-400">(opsional)</span></label>
          <label htmlFor="cj-reference-files" className={`btn-ghost inline-flex cursor-pointer items-center rounded-xl px-3.5 py-2 text-xs font-bold ${busy ? "pointer-events-none opacity-60" : ""}`}>
            + Pilih file referensi
          </label>
          <input
            id="cj-reference-files" type="file" multiple accept={ACCEPTED_FILE_EXTENSIONS} className="sr-only" disabled={busy}
            onChange={(e) => setReferenceFiles(Array.from(e.target.files ?? []))}
          />
          <ul aria-label="Jenis file yang didukung" className="mt-2 flex flex-wrap gap-1.5">
            {["PDF", "PNG/JPG", "SVG", "DOCX", "XLSX", "PPTX", "CDR", "AI", "PSD"].map((type) => (
              <li key={type} className="rounded-full bg-zinc-100 px-2 py-0.5 text-[10px] font-semibold text-zinc-600 ring-1 ring-inset ring-zinc-200/80">{type}</li>
            ))}
          </ul>
          {referenceFiles.length > 0 && (
            <ul className="mt-2 space-y-1 rounded-xl bg-indigo-50/70 p-2 text-xs text-indigo-950" aria-live="polite">
              {referenceFiles.map((file, index) => (
                <li key={`${file.name}-${file.lastModified}-${index}`} className="flex min-w-0 justify-between gap-2">
                  <span className="min-w-0 truncate">{file.name}</span>
                  <span className="shrink-0 text-indigo-700">{(file.size / 1048576).toFixed(1)} MB</span>
                </li>
              ))}
            </ul>
          )}
        </div>
        <div className="flex justify-end gap-2 border-t border-zinc-200/70 pt-3">
          <button type="button" className="btn-ghost rounded-xl px-5 py-2.5 text-sm font-semibold" onClick={onClose} disabled={busy}>Batal</button>
          <button className="btn-primary rounded-xl px-6 py-2.5 text-sm font-bold text-white" disabled={busy}>{busy ? (referenceFiles.length ? "Menyimpan & mengunggah…" : "Menyimpan…") : "Simpan job"}</button>
        </div>
        </div>
      </form>
    </div>
  );
}
