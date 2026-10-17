"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { AuthHighlights, AuthShell, FieldError, btnPrimary, inputCls } from "@/components/auth-shell";
import { createClient } from "@/lib/backend/client";

function MailIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <rect width="20" height="16" x="2" y="4" rx="2" /><path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7" />
    </svg>
  );
}

function LockIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <rect width="18" height="11" x="3" y="11" rx="2" ry="2" /><path d="M7 11V7a5 5 0 0 1 10 0v4" />
    </svg>
  );
}

function EyeIcon({ off }: { off?: boolean }) {
  return off ? (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49" /><path d="M14.084 14.158a3 3 0 0 1-4.242-4.242" /><path d="M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143" /><path d="m2 2 20 20" />
    </svg>
  ) : (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0" /><circle cx="12" cy="12" r="3" />
    </svg>
  );
}

function Spinner() {
  return (
    <svg className="animate-spin" width="15" height="15" viewBox="0 0 24 24" fill="none" aria-hidden>
      <circle cx="12" cy="12" r="10" stroke="currentColor" strokeOpacity="0.25" strokeWidth="3" />
      <path d="M22 12a10 10 0 0 0-10-10" stroke="currentColor" strokeWidth="3" strokeLinecap="round" />
    </svg>
  );
}

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPw, setShowPw] = useState(false);
  const [mfaMode, setMfaMode] = useState<"none" | "challenge" | "setup">("none");
  const [mfaCode, setMfaCode] = useState("");
  const [mfaSecret, setMfaSecret] = useState<string | null>(null);
  const [mfaSetupUrl, setMfaSetupUrl] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  return (
    <AuthShell
      title="Selamat datang kembali"
      subtitle="Masuk untuk mengelola proyek dan kolaborasi tim freelance Anda."
      footnote="Akun Freelancer perlu memverifikasi email terlebih dahulu, lalu menunggu tinjauan Admin atau Super Admin."
      split={<AuthHighlights />}
    >
      <form
        className="space-y-3"
        onSubmit={async (e) => {
          e.preventDefault();
          setError(null);
          if (!email.trim() || !password) { setError("Isi email dan kata sandi"); return; }
          setBusy(true);
          try {
            const client = createClient();
            const { error: err } = await client.auth.signInWithPassword({
              email: email.trim(), password, ...(mfaMode === "challenge" ? { otp: mfaCode } : {}),
            });
            if (err) {
              if (err.code === "MFA_REQUIRED") { setMfaMode("challenge"); setError("Masukkan kode 6 digit dari aplikasi autentikator."); return; }
              if (err.code === "MFA_SETUP_REQUIRED") {
                const enrollment = await client.auth.beginMfaEnrollment({ email: email.trim(), password });
                setMfaSecret(enrollment.secret);
                setMfaSetupUrl(enrollment.otpauthUrl);
                setMfaMode("setup");
                setError("Akun Super Admin perlu menghubungkan autentikator terlebih dahulu.");
                return;
              }
              setError("Email atau kata sandi salah.");
              return;
            }
            router.push("/dashboard");
            router.refresh();
          } catch {
            setError("Tidak dapat terhubung. Periksa koneksi lalu coba lagi.");
          } finally {
            setBusy(false);
          }
        }}
      >
        <div>
          <label htmlFor="login-email" className="mb-1 block text-sm font-medium text-zinc-700">Email</label>
          <span className="relative block">
            <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-zinc-400"><MailIcon /></span>
            <input id="login-email" className={`${inputCls} pl-9`} type="email" autoComplete="email" placeholder="nama@contoh.id" value={email} onChange={(e) => setEmail(e.target.value)} required />
          </span>
        </div>
        <div>
          <span className="mb-1 flex items-center justify-between">
            <label htmlFor="login-password" className="block text-sm font-medium text-zinc-700">Kata sandi</label>
            <Link href="/lupa-password" className="text-xs font-medium text-indigo-600 hover:text-indigo-800">Lupa?</Link>
          </span>
          <span className="relative block">
            <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-zinc-400"><LockIcon /></span>
            <input id="login-password" className={`${inputCls} pl-9 pr-11`} type={showPw ? "text" : "password"} autoComplete="current-password" placeholder="••••••••" value={password} onChange={(e) => setPassword(e.target.value)} required />
            <button type="button" aria-label={showPw ? "Sembunyikan kata sandi" : "Tampilkan kata sandi"} className="absolute right-1.5 top-1/2 -translate-y-1/2 rounded-lg p-1.5 text-zinc-400 hover:bg-zinc-100 hover:text-zinc-700" onClick={() => setShowPw(!showPw)}>
              <EyeIcon off={showPw} />
            </button>
          </span>
        </div>
        {mfaMode !== "none" && (
          <div className="space-y-2 rounded-xl border border-indigo-100 bg-indigo-50 p-3">
            {mfaMode === "setup" && mfaSecret && (
              <div className="space-y-1 text-xs text-indigo-950">
                <p>Tambahkan Threadline ke aplikasi autentikator menggunakan kunci ini:</p>
                <code className="block select-all break-all rounded-lg bg-white p-2 font-mono">{mfaSecret}</code>
                {mfaSetupUrl && <p className="break-all text-[10px] text-indigo-700">{mfaSetupUrl}</p>}
                <p>Setelah tersimpan, masukkan kode yang tampil untuk mengaktifkannya.</p>
              </div>
            )}
            <label className="block space-y-1 text-sm font-medium text-zinc-700">
              <span className="block">Kode autentikator</span>
              <input className={inputCls} inputMode="numeric" autoComplete="one-time-code" value={mfaCode} onChange={(e) => setMfaCode(e.target.value.replace(/\D/g, "").slice(0, 6))} required minLength={6} maxLength={6} />
            </label>
          </div>
        )}
        <FieldError msg={error} />
        <button
          type={mfaMode === "setup" ? "button" : "submit"}
          className={`${btnPrimary} flex items-center justify-center gap-2`}
          disabled={busy}
          onClick={mfaMode === "setup" ? async (event) => {
            event.preventDefault();
            setError(null);
            setBusy(true);
            try {
              const { error: err } = await createClient().auth.confirmMfaEnrollment({ email: email.trim(), password, code: mfaCode });
              if (err) { setError(err.message || "Kode autentikator tidak valid."); return; }
              router.push("/dashboard");
              router.refresh();
            } catch { setError("Autentikator belum dapat diaktifkan. Periksa kodenya lalu coba lagi."); }
            finally { setBusy(false); }
          } : undefined}
        >
          {busy && <Spinner />} {busy ? "Memeriksa…" : mfaMode === "setup" ? "Aktifkan & masuk" : mfaMode === "challenge" ? "Verifikasi & masuk" : "Masuk ke Threadline"}
        </button>
      </form>
      <div className="my-4 flex items-center gap-3 text-[11px] font-medium uppercase tracking-widest text-zinc-400">
        <span className="h-px flex-1 bg-zinc-200" /> atau <span className="h-px flex-1 bg-zinc-200" />
      </div>
      <Link href="/register" className="btn-ghost block rounded-xl px-3 py-2.5 text-center text-sm font-semibold">
        Buat akun Freelancer baru
      </Link>
    </AuthShell>
  );
}
