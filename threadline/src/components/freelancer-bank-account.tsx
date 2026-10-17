"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { useReadyStore } from "@/lib/store-context";
import { validateFreelancerBankAccount } from "@/lib/domain";

export function FreelancerBankAccountForm() {
  const { data, saveFreelancerBankAccount, signOut, refresh } = useReadyStore();
  const router = useRouter();
  const [bankName, setBankName] = useState(data.freelancerBankAccount?.bankName ?? "");
  const [accountNumber, setAccountNumber] = useState(data.freelancerBankAccount?.accountNumber ?? "");
  const [accountHolder, setAccountHolder] = useState(data.freelancerBankAccount?.accountHolder ?? "");
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const [isError, setIsError] = useState(false);

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const account = { bankName, accountNumber, accountHolder };
    const validationError = validateFreelancerBankAccount(account);
    if (validationError) {
      setMessage(validationError);
      setIsError(true);
      return;
    }
    setSaving(true);
    setMessage("");
    try {
      const result = await saveFreelancerBankAccount(account);
      setIsError(!result.ok);
      setMessage(result.ok ? "Rekening bank berhasil disimpan." : (result.error ?? "Rekening gagal disimpan."));
    } catch {
      setIsError(true);
      setMessage("Koneksi terputus. Periksa jaringan lalu coba lagi.");
    } finally {
      setSaving(false);
    }
  };

  if (data.freelancerBankAccountError) {
    return (
      <div>
        <section className="glass-card-gradient w-full max-w-xl p-6 sm:p-8">
          <div className="text-xs font-bold uppercase tracking-[0.18em] text-indigo-600">Threadline · Rekening freelancer</div>
          <h1 className="mt-2 text-2xl font-extrabold tracking-tight text-zinc-900">Data rekening belum dapat dimuat</h1>
          <p className="mt-2 text-sm leading-6 text-zinc-600">Coba muat ulang halaman. Jika masih gagal, hubungi Admin agar pengaturan rekening dapat diperiksa.</p>
          <div className="mt-5 flex flex-wrap gap-2">
            <button className="btn-primary rounded-xl px-4 py-2.5 text-sm font-bold text-white" onClick={refresh}>Muat ulang</button>
            <button className="btn-ghost rounded-xl px-4 py-2.5 text-sm font-semibold" onClick={() => { void signOut().then(() => router.replace("/login")); }}>Keluar</button>
          </div>
        </section>
      </div>
    );
  }

  return (
    <div>
      <section className="glass-card-gradient w-full max-w-none overflow-hidden">
        <div className="border-b border-indigo-100/80 px-6 py-5 sm:px-8">
          <div className="text-xs font-bold uppercase tracking-[0.18em] text-indigo-600">Threadline · Pembayaran freelancer</div>
          <div className="mt-2 flex flex-wrap items-start justify-between gap-3">
            <div>
              <h1 className="text-2xl font-extrabold tracking-tight text-zinc-900">
                Rekening bank
              </h1>
              <p className="mt-1 max-w-lg text-sm leading-6 text-zinc-600">
                Simpan rekening untuk pembayaran fee. Data ini dapat dilengkapi sebelum payout pertama dan tidak menjadi syarat menerima job.
              </p>
            </div>
          </div>
        </div>

        <form className="space-y-4 px-6 py-5 sm:px-8 sm:py-6" onSubmit={submit}>
          <div className="flex gap-3 rounded-2xl border border-indigo-100 bg-gradient-to-r from-indigo-50 via-white to-fuchsia-50/70 px-4 py-3.5 shadow-sm shadow-indigo-100/40">
            <span className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-indigo-100 text-indigo-700" aria-hidden="true">
              <svg viewBox="0 0 24 24" fill="none" className="h-4 w-4" stroke="currentColor" strokeWidth="1.8">
                <circle cx="12" cy="12" r="9" />
                <path strokeLinecap="round" strokeLinejoin="round" d="M12 11v5m0-8h.01" />
              </svg>
            </span>
            <div className="min-w-0 pt-0.5">
              <p className="text-sm font-bold text-indigo-950">Rekening bank saja</p>
              <p className="mt-1 text-sm leading-5 text-zinc-600">Gunakan rekening bank atas nama pemilik rekening.</p>
              <p className="mt-1 text-xs leading-5 text-zinc-500">
                E-wallet seperti <strong className="font-semibold text-zinc-700">GoPay, OVO, DANA, ShopeePay, dan LinkAja</strong> tidak diperkenankan.
              </p>
            </div>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <label className="space-y-1.5 text-sm font-semibold text-zinc-800">
              <span>Nama bank <span className="text-rose-600">*</span></span>
              <input
                className="input w-full px-3.5 py-2.5 text-sm font-normal"
                value={bankName}
                onChange={(event) => setBankName(event.target.value)}
                placeholder="Contoh: BCA, BRI, Mandiri"
                autoComplete="organization"
                maxLength={80}
                required
              />
            </label>
            <label className="space-y-1.5 text-sm font-semibold text-zinc-800">
              <span>Nomor rekening <span className="text-rose-600">*</span></span>
              <input
                className="input w-full px-3.5 py-2.5 text-sm font-normal tabular-nums"
                value={accountNumber}
                onChange={(event) => setAccountNumber(event.target.value.replace(/\D/g, "").slice(0, 30))}
                placeholder="Masukkan nomor rekening"
                inputMode="numeric"
                autoComplete="off"
                maxLength={30}
                required
              />
              <span className="block text-xs font-normal text-zinc-500">Angka saja, 5–30 digit.</span>
            </label>
          </div>

          <label className="block space-y-1.5 text-sm font-semibold text-zinc-800">
            <span>Nama pemilik rekening <span className="text-rose-600">*</span></span>
            <input
              className="input w-full px-3.5 py-2.5 text-sm font-normal"
              value={accountHolder}
              onChange={(event) => setAccountHolder(event.target.value)}
              placeholder="Sesuai nama yang terdaftar di bank"
              autoComplete="name"
              maxLength={100}
              required
            />
          </label>

          {message && (
            <p role="status" className={`rounded-xl px-3.5 py-2.5 text-sm ${isError ? "bg-rose-50 text-rose-800 ring-1 ring-inset ring-rose-200" : "bg-emerald-50 text-emerald-800 ring-1 ring-inset ring-emerald-200"}`}>
              {message}
            </p>
          )}

          <div className="flex flex-wrap items-center justify-between gap-3 border-t border-indigo-100/80 pt-4">
            <span className="text-xs text-zinc-500">Anda melihat rekening sendiri; Finance dan Super Admin membukanya melalui jalur ber-audit. Admin tidak dapat membaca rekening.</span>
            <button type="submit" className="btn-primary rounded-xl px-5 py-2.5 text-sm font-bold text-white" disabled={saving}>
              {saving ? "Menyimpan…" : "Simpan rekening"}
            </button>
          </div>
        </form>
      </section>
    </div>
  );
}
