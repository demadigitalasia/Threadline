"use client";

import { useState } from "react";
import { formatWIB } from "@/lib/domain";
import { useReadyStore } from "@/lib/store-context";
import type { Toast } from "./threadline-ui";

export function FreelancerRegistrationsPanel({ onToast }: { onToast: Toast }) {
  const { data, refresh, reviewFreelancerRegistration } = useReadyStore();
  const [reasons, setReasons] = useState<Record<string, string>>({});
  const [workingId, setWorkingId] = useState<string | null>(null);
  const requests = data.pendingFreelancerRegistrations;

  const review = async (profileId: string, decision: "approve" | "reject") => {
    const reason = reasons[profileId]?.trim() ?? "";
    if (decision === "reject" && !reason) {
      onToast("Isi catatan penolakan terlebih dahulu.");
      return;
    }
    setWorkingId(profileId);
    const result = await reviewFreelancerRegistration(profileId, decision, reason);
    setWorkingId(null);
    if (!result.ok) {
      onToast(result.error ?? "Keputusan pendaftaran gagal disimpan.");
      return;
    }
    setReasons((current) => {
      const next = { ...current };
      delete next[profileId];
      return next;
    });
    onToast(decision === "approve" ? "Akun freelancer disetujui." : "Pendaftaran freelancer ditolak.");
  };

  return (
    <div className="space-y-4">
      <section className="auth-side relative overflow-hidden rounded-3xl p-5 text-white sm:p-6">
        <p className="text-[10px] font-bold uppercase tracking-[0.2em] text-white/65">Pemeriksaan akun</p>
        <div className="mt-2 flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-extrabold tracking-tight sm:text-3xl">Pendaftaran Freelancer</h1>
            <p className="mt-1 max-w-2xl text-sm text-white/75">Periksa data pendaftar, lalu setujui atau tolak. Akun baru dapat digunakan setelah disetujui.</p>
          </div>
          <span className="rounded-full bg-white/12 px-3 py-1.5 text-xs font-semibold ring-1 ring-inset ring-white/20">
            {requests.length} menunggu
          </span>
        </div>
      </section>

      <section className="glass-card overflow-hidden">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-zinc-200/80 px-4 py-3 sm:px-5">
          <div>
            <h2 className="text-sm font-extrabold">Antrean pendaftaran</h2>
            <p className="mt-0.5 text-xs text-zinc-500">Hanya Admin dan Super Admin yang dapat melihat nomor WhatsApp dan mengambil keputusan.</p>
          </div>
          <button type="button" onClick={refresh} className="btn-ghost rounded-lg px-3 py-1.5 text-xs font-semibold">Muat ulang</button>
        </div>

        {requests.length === 0 ? (
          <div className="px-5 py-12 text-center">
            <span className="mx-auto flex h-11 w-11 items-center justify-center rounded-2xl bg-emerald-50 text-lg font-bold text-emerald-700 ring-1 ring-inset ring-emerald-200" aria-hidden>✓</span>
            <h3 className="mt-3 text-sm font-bold">Tidak ada pendaftaran tertunda</h3>
            <p className="mt-1 text-xs text-zinc-500">Pendaftar baru akan muncul di sini setelah mengirim formulir.</p>
          </div>
        ) : (
          <div className="divide-y divide-zinc-200/80">
            {requests.map((request) => (
              <article key={request.profileId} className="grid gap-4 px-4 py-4 sm:px-5 lg:grid-cols-[minmax(0,1fr)_minmax(16rem,0.9fr)_auto] lg:items-center">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="truncate text-sm font-extrabold">{request.name}</h3>
                    <span className="rounded-full bg-amber-50 px-2 py-0.5 text-[10px] font-bold text-amber-800 ring-1 ring-inset ring-amber-200">Menunggu</span>
                  </div>
                  <a className="mt-1 block truncate text-sm text-indigo-700 underline decoration-indigo-200 underline-offset-2" href={`mailto:${request.email}`}>{request.email}</a>
                  <p className="mt-1 text-xs text-zinc-500">WhatsApp: <span className="font-semibold text-zinc-700">{request.whatsapp || "Tidak tersedia"}</span></p>
                  <p className="mt-1 text-[11px] text-zinc-400">Didaftarkan {formatWIB(request.requestedAt)} WIB</p>
                </div>

                <label className="block text-xs font-semibold text-zinc-700">
                  Catatan keputusan
                  <textarea
                    className="input mt-1 block min-h-20 w-full resize-y px-3 py-2 text-sm font-normal"
                    value={reasons[request.profileId] ?? ""}
                    onChange={(event) => setReasons((current) => ({ ...current, [request.profileId]: event.target.value }))}
                    maxLength={500}
                    placeholder="Wajib diisi jika pendaftaran ditolak"
                  />
                </label>

                <div className="flex flex-wrap gap-2 lg:justify-end">
                  <button
                    type="button"
                    onClick={() => { void review(request.profileId, "reject"); }}
                    disabled={workingId === request.profileId}
                    className="rounded-xl border border-rose-200 bg-white px-3 py-2 text-sm font-bold text-rose-700 hover:bg-rose-50 disabled:opacity-50"
                  >
                    Tolak
                  </button>
                  <button
                    type="button"
                    onClick={() => { void review(request.profileId, "approve"); }}
                    disabled={workingId === request.profileId}
                    className="btn-primary rounded-xl px-3 py-2 text-sm font-bold text-white disabled:opacity-50"
                  >
                    {workingId === request.profileId ? "Menyimpan…" : "Setujui"}
                  </button>
                </div>
              </article>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
