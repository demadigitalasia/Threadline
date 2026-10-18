"use client";

import Link from "next/link";
import { useState } from "react";
import { AuthShell, FieldError, btnPrimary, inputCls } from "@/components/auth-shell";
import { createClient } from "@/lib/backend/client";

export default function RegisterPage() {
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [whatsapp, setWhatsapp] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [sentTo, setSentTo] = useState<string | null>(null);

  return (
    <AuthShell
      title="Daftar sebagai Freelancer"
      subtitle="Isi data Anda untuk mengajukan akun freelancer. Admin akan meninjau pendaftaran sebelum akses dibuka."
      variant="register"
    >
      {!sentTo ? (
        <form
          className="space-y-3"
          onSubmit={async (e) => {
            e.preventDefault();
            setError(null);
            if (name.trim().length < 3) { setError("Nama minimal 3 karakter"); return; }
            const whatsappValue = whatsapp.trim();
            const whatsappDigits = whatsappValue.replace(/\D/g, "").length;
            if (!/^\+?[\d\s().-]+$/.test(whatsappValue) || whatsappDigits < 9 || whatsappDigits > 15) {
              setError("Masukkan nomor WhatsApp yang valid, termasuk kode negara bila diperlukan");
              return;
            }
            if (password.length < 8) { setError("Kata sandi minimal 8 karakter"); return; }
            if (password !== confirm) { setError("Konfirmasi kata sandi tidak sama"); return; }
            setBusy(true);
            try {
              const { error: signupError } = await createClient().auth.signUp({
                email: email.trim(),
                password,
                options: {
                  data: { name: name.trim(), whatsapp: whatsappValue },
                },
              });
              if (signupError) {
                setError("Pendaftaran belum dapat diproses. Periksa koneksi dan coba lagi sebentar.");
                return;
              }
              // Keep the same response for successful, duplicate, and rejected
              // sign-ups so this screen cannot confirm whether an email exists.
              setSentTo(email.trim());
            } catch {
              setError("Tidak dapat terhubung. Periksa koneksi lalu coba lagi.");
            } finally {
              setBusy(false);
            }
          }}
        >
          <label className="block space-y-1 text-sm font-medium text-zinc-700">
            <span className="block">Nama Lengkap</span>
            <input className={inputCls} autoComplete="name" placeholder="cth. Rian Pratama" value={name} onChange={(e) => setName(e.target.value)} required minLength={3} maxLength={100} />
          </label>
          <label className="block space-y-1 text-sm font-medium text-zinc-700">
            <span className="block">Email</span>
            <input className={inputCls} type="email" autoComplete="email" placeholder="nama@contoh.id" value={email} onChange={(e) => setEmail(e.target.value)} required />
          </label>
          <label className="block space-y-1 text-sm font-medium text-zinc-700">
            <span className="block">No. WhatsApp</span>
            <input className={inputCls} type="tel" inputMode="tel" autoComplete="tel" placeholder="08xx atau +62 8xx" value={whatsapp} onChange={(e) => setWhatsapp(e.target.value)} required maxLength={24} />
          </label>
          <label className="block space-y-1 text-sm font-medium text-zinc-700">
            <span className="block">Kata sandi (min 8)</span>
            <input className={inputCls} type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} required minLength={8} maxLength={128} />
          </label>
          <label className="block space-y-1 text-sm font-medium text-zinc-700">
            <span className="block">Konfirmasi kata sandi</span>
            <input className={inputCls} type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} required maxLength={128} />
          </label>
          <FieldError msg={error} />
          <button className={btnPrimary} disabled={busy}>{busy ? "Mendaftar…" : "Buat akun Freelancer"}</button>
        </form>
      ) : (
        <div className="space-y-2 text-sm">
          <div className="rounded-xl border border-emerald-200 bg-emerald-50 p-2.5 text-xs font-medium text-emerald-900">
            Jika email <b>{sentTo}</b> dapat didaftarkan, tautan verifikasi akan dikirim. Verifikasi email terlebih dahulu; setelah itu Admin akan meninjau pendaftaran Anda. Periksa juga folder spam.
          </div>
          <Link href="/login" className="btn-primary block rounded-xl px-3 py-2.5 text-center text-sm font-semibold text-white">Ke halaman masuk →</Link>
        </div>
      )}
      <div className="mt-3 text-xs">
        <Link href="/login" className="font-medium text-indigo-600 underline decoration-indigo-300 underline-offset-2 hover:text-indigo-800">Sudah punya akun? Masuk</Link>
      </div>
    </AuthShell>
  );
}
