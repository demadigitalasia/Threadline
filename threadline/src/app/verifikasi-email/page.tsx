"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { Suspense, useEffect, useState } from "react";
import { AuthShell, FieldError } from "@/components/auth-shell";
import { exchangeAuthCode } from "@/lib/backend/auth-callback";
import { createClient } from "@/lib/backend/client";

function VerifyBox() {
  const router = useRouter();
  const params = useSearchParams();
  const [state, setState] = useState<"working" | "ok" | "fail">("working");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    const code = params.get("code");
    const callbackError = params.get("error") || params.get("error_code") || params.get("error_description");
    const sb = createClient();
    const done = (errMsg: string | null) => {
      if (!active) return;
      if (errMsg) { setError(errMsg); setState("fail"); }
      else setState("ok");
    };
    if (callbackError) {
      done("Tautan tidak valid atau kedaluwarsa.");
      return () => { active = false; };
    }
    if (!code) {
      done("Tautan verifikasi tidak ditemukan. Buka tautan dari email yang sama di browser ini.");
      return () => { active = false; };
    }
    void exchangeAuthCode(code).then(async (ok) => {
      if (!ok) { done("Tautan tidak valid atau kedaluwarsa."); return; }
      try {
        const { data, error: err } = await sb.auth.getUser();
        done(!err && data.user?.email_confirmed_at ? null : "Tautan tidak valid atau kedaluwarsa.");
      } catch {
        done("Tautan tidak valid atau kedaluwarsa.");
      }
    });
    return () => { active = false; };
  }, [params]);

  if (state === "working") return <div className="text-sm text-zinc-500">Memverifikasi…</div>;
  if (state === "ok") {
    return (
      <div className="space-y-2 text-sm">
        <div className="rounded-xl border border-emerald-200 bg-emerald-50 p-2.5 text-xs font-medium text-emerald-900">
          Email terverifikasi. Selamat datang di Threadline.
        </div>
        <button className="btn-primary w-full rounded-xl px-3 py-2.5 text-sm font-semibold text-white" onClick={() => { router.push("/dashboard"); router.refresh(); }}>
          Buka aplikasi →
        </button>
      </div>
    );
  }
  return (
    <div className="space-y-2 text-sm">
      <FieldError msg={error} />
      <div className="text-xs"><Link href="/login" className="font-medium text-indigo-600 underline decoration-indigo-300 underline-offset-2 hover:text-indigo-800">Kembali masuk</Link></div>
    </div>
  );
}

export default function VerifyEmailPage() {
  return (
    <AuthShell title="Verifikasi email" subtitle="Dibuka dari tautan email verifikasi.">
      <Suspense fallback={<div className="text-sm text-zinc-500">Memuat…</div>}>
        <VerifyBox />
      </Suspense>
    </AuthShell>
  );
}
