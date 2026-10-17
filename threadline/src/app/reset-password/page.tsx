"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { Suspense, useEffect, useState } from "react";
import { AuthShell, FieldError, btnPrimary, inputCls } from "@/components/auth-shell";
import { exchangeAuthCode } from "@/lib/backend/auth-callback";
import { createClient } from "@/lib/backend/client";

function ResetForm() {
  const router = useRouter();
  const params = useSearchParams();
  const [status, setStatus] = useState<"checking" | "ready" | "invalid">("checking");
  const [pw, setPw] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // Password reset links use a one-time code exchanged for a restricted reset session.
  useEffect(() => {
    let active = true;
    const code = params.get("code");
    const callbackError = params.get("error") || params.get("error_code") || params.get("error_description");
    if (callbackError) {
      const timeout = window.setTimeout(() => { if (active) setStatus("invalid"); }, 0);
      return () => { active = false; window.clearTimeout(timeout); };
    }

    if (!code) {
      const timeout = window.setTimeout(() => { if (active) setStatus("invalid"); }, 0);
      return () => { active = false; window.clearTimeout(timeout); };
    }
    void exchangeAuthCode(code).then((ok) => {
      if (active) setStatus(ok ? "ready" : "invalid");
    });
    return () => { active = false; };
  }, [params]);

  if (status === "checking") return <div className="text-sm text-zinc-500">Menyiapkan sesi reset…</div>;

  if (status === "invalid") {
    return (
      <div className="space-y-2 text-sm">
        <FieldError msg="Tautan tidak valid atau kedaluwarsa. Minta tautan reset baru." />
        <div className="text-xs"><Link href="/lupa-password" className="font-medium text-indigo-600 underline decoration-indigo-300 underline-offset-2 hover:text-indigo-800">Minta tautan baru</Link></div>
      </div>
    );
  }

  return (
    <form
      className="space-y-2"
      onSubmit={async (e) => {
        e.preventDefault();
        setError(null);
        if (pw.length < 8) { setError("Kata sandi minimal 8 karakter"); return; }
        if (pw !== confirm) { setError("Konfirmasi tidak sama"); return; }
        setBusy(true);
        try {
          const { error: err } = await createClient().auth.updateUser({ password: pw });
          if (err) { setError("Kata sandi belum dapat disimpan. Coba lagi atau minta tautan baru."); return; }
          router.push("/dashboard");
          router.refresh();
        } catch {
          setError("Tidak dapat terhubung. Periksa koneksi lalu coba lagi.");
        } finally {
          setBusy(false);
        }
      }}
    >
      <label className="block text-xs text-zinc-500">Kata sandi baru (min 8)
        <input className={inputCls} type="password" autoComplete="new-password" value={pw} onChange={(e) => setPw(e.target.value)} required minLength={8} />
      </label>
      <label className="block text-xs text-zinc-500">Konfirmasi
        <input className={inputCls} type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} required />
      </label>
      <FieldError msg={error} />
      <button className={btnPrimary} disabled={busy}>{busy ? "Menyimpan…" : "Simpan & masuk"}</button>
      <div className="text-xs"><Link href="/lupa-password" className="font-medium text-indigo-600 underline decoration-indigo-300 underline-offset-2 hover:text-indigo-800">Minta tautan baru</Link></div>
    </form>
  );
}

export default function ResetPasswordPage() {
  return (
    <AuthShell title="Buat kata sandi baru" subtitle="Dibuka dari tautan email reset.">
      <Suspense fallback={<div className="text-sm text-zinc-500">Memuat…</div>}>
        <ResetForm />
      </Suspense>
    </AuthShell>
  );
}
