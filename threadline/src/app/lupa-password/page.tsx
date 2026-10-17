"use client";

import Link from "next/link";
import { useState } from "react";
import { AuthHighlights, AuthShell, FieldError, btnPrimary, inputCls } from "@/components/auth-shell";
import { createClient } from "@/lib/backend/client";

export default function ForgotPasswordPage() {
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);

  return (
    <AuthShell title="Lupa kata sandi" subtitle="Masukkan email akun Anda untuk menerima tautan reset." split={<AuthHighlights />}>
      {!sent ? (
        <form
          className="space-y-3"
          onSubmit={async (e) => {
            e.preventDefault();
            setError(null);
            if (!email.trim()) { setError("Isi email"); return; }
            setBusy(true);
            try {
              const { error: err } = await createClient().auth.resetPasswordForEmail(email.trim());
              if (err) { setError("Permintaan reset belum dapat diproses. Coba beberapa saat lagi."); return; }
              setSent(true);
            } catch {
              setError("Tidak dapat terhubung. Periksa koneksi lalu coba lagi.");
            } finally {
              setBusy(false);
            }
          }}
        >
          <label className="block space-y-1 text-sm font-medium text-zinc-700">
            <span className="block">Email terdaftar</span>
            <input className={inputCls} type="email" autoComplete="email" placeholder="nama@contoh.id" value={email} onChange={(e) => setEmail(e.target.value)} required />
          </label>
          <FieldError msg={error} />
          <button className={btnPrimary} disabled={busy}>{busy ? "Mengirim…" : "Kirim tautan reset"}</button>
        </form>
      ) : (
          <div className="rounded-xl border border-emerald-200 bg-emerald-50 p-2.5 text-xs font-medium text-emerald-900">
          Jika email terdaftar, tautan reset telah dikirim. Periksa kotak masuk dan folder spam/promosi.
        </div>
      )}
      <div className="mt-3 text-xs"><Link href="/login" className="font-medium text-indigo-600 underline decoration-indigo-300 underline-offset-2 hover:text-indigo-800">Kembali masuk</Link></div>
    </AuthShell>
  );
}
