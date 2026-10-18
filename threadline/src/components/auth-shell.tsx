import type { ReactNode } from "react";
import Image from "next/image";
import { ThreadlineLogo } from "@/components/threadline-logo";

function BrandMark({ light = false }: { light?: boolean }) {
  return <ThreadlineLogo surface={light ? "transparent" : "tile"} className="w-[208px]" />;
}

function Footnote({ children }: { children: ReactNode }) {
  return (
    <p className="mt-5 border-t border-zinc-200 pt-4 text-xs leading-relaxed text-zinc-500">
      {children}
    </p>
  );
}

export function AuthShell({ title, subtitle, children, split, footnote, variant = "standard" }: {
  title: string; subtitle: string; children: ReactNode; split?: ReactNode; footnote?: ReactNode;
  variant?: "standard" | "register";
}) {
  if (!split && variant !== "register") {
    return (
      <div className="auth-bg flex min-h-screen items-start justify-center px-4 py-8 text-zinc-900 lg:items-center lg:py-10">
        <div className="glass-card w-full max-w-md p-6 sm:p-8">
          <BrandMark />
          <h2 className="mt-7 text-xl font-extrabold tracking-tight">{title}</h2>
          <p className="mt-1.5 text-sm leading-relaxed text-zinc-500">{subtitle}</p>
          <div className="mt-6">{children}</div>
          {footnote && <Footnote>{footnote}</Footnote>}
        </div>
      </div>
    );
  }
  return (
    <div className="auth-bg flex min-h-screen items-start justify-center px-4 py-8 text-zinc-900 lg:items-center lg:py-10">
      <div className="glass-card grid w-full max-w-md overflow-hidden lg:max-w-5xl lg:grid-cols-2">
        <div className={`auth-side hidden flex-col justify-between gap-8 overflow-hidden p-8 text-white lg:flex lg:p-10 ${variant === "register" ? "auth-side-register" : ""}`}>
          <div aria-hidden className="pointer-events-none absolute -bottom-24 -right-10 z-0 h-96 w-96 opacity-[0.12]">
            <Image src="/threadline-mark-v2.png" alt="" fill sizes="384px" className="object-contain" />
          </div>
          <div className="relative z-10">
            <BrandMark light />
            {variant === "register" ? (
              <>
                <p className="mt-7 text-[11px] font-bold uppercase tracking-[0.22em] text-teal-100">Mulai di Threadline</p>
                <p className="mt-2 max-w-sm text-2xl font-extrabold leading-snug tracking-tight">
                  Bangun alur kerja freelance Anda.
                </p>
                <p className="mt-2 max-w-sm text-sm leading-relaxed text-white/75">
                  Satu profil untuk menerima penugasan dan mengelola pekerjaan bersama tim.
                </p>
                <ol className="mt-6 space-y-3">
                  <RegisterStep number="01" title="Kirim data pendaftaran" desc="Isi nama lengkap, email, WhatsApp, dan kata sandi." />
                  <RegisterStep number="02" title="Tunggu pemeriksaan admin" desc="Admin akan menyetujui atau menolak pendaftaran Anda." />
                  <RegisterStep number="03" title="Mulai setelah disetujui" desc="Masuk untuk menerima tugas dan memantau progres pekerjaan." />
                </ol>
              </>
            ) : (
              <>
                <p className="mt-7 max-w-sm text-2xl font-extrabold leading-snug tracking-tight">
                  Satu ruang kerja untuk mengelola proyek dan kolaborasi freelancer.
                </p>
                <div className="mt-7 space-y-3">{split}</div>
              </>
            )}
          </div>
          {variant === "register" ? (
            <p className="relative z-10 border-t border-white/20 pt-4 text-xs leading-relaxed text-white/75">
              Pendaftaran ditinjau manual oleh Admin sebelum akun dapat digunakan.
            </p>
          ) : (
            <p className="relative z-10 border-t border-white/20 pt-4 text-xs leading-relaxed text-white/75">
              Admin mengelola proyek; Freelancer mengerjakan tugas, sementara Finance memantau rekap fee.
            </p>
          )}
        </div>
        <div className="flex flex-col justify-center p-6 sm:p-8 lg:p-10">
          <div className={`auth-side relative -mx-6 -mt-6 mb-6 overflow-hidden px-6 py-5 text-white sm:-mx-8 sm:-mt-8 sm:px-8 sm:py-6 lg:hidden ${variant === "register" ? "auth-side-register" : ""}`}>
            <BrandMark light />
            {variant === "register" ? (
              <>
                <p className="mt-4 text-[10px] font-bold uppercase tracking-[0.2em] text-teal-100">Mulai di Threadline</p>
                <p className="mt-1 max-w-sm text-sm leading-relaxed text-white/80">Ajukan profil. Admin akan meninjau sebelum akses dibuka.</p>
              </>
            ) : (
              <p className="mt-3 max-w-sm text-sm leading-relaxed text-white/80">Satu ruang kerja untuk proyek dan kolaborasi freelancer.</p>
            )}
          </div>
          <h2 className="text-2xl font-extrabold tracking-tight">{title}</h2>
          <p className="mt-1.5 text-sm leading-relaxed text-zinc-500">{subtitle}</p>
          <div className="mt-7">{children}</div>
          {footnote && <Footnote>{footnote}</Footnote>}
        </div>
      </div>
    </div>
  );
}

function RegisterStep({ number, title, desc }: { number: string; title: string; desc: string }) {
  return (
    <li className="flex items-start gap-3 rounded-xl border border-white/15 bg-slate-950/15 p-3 backdrop-blur-sm">
      <span className="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-full border border-white/25 bg-white/10 text-[10px] font-bold tracking-wide text-teal-100">
        {number}
      </span>
      <span>
        <span className="block text-sm font-bold leading-tight">{title}</span>
        <span className="mt-1 block text-xs leading-relaxed text-white/75">{desc}</span>
      </span>
    </li>
  );
}

export function AuthFeature({ title, desc }: { title: string; desc: string }) {
  return (
    <div className="auth-feature flex items-start gap-2.5 p-3">
      <span className="auth-check mt-0.5 inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-[11px] font-bold" aria-hidden>✓</span>
      <span>
        <span className="block text-sm font-bold leading-tight">{title}</span>
        <span className="block text-xs leading-relaxed text-white/75">{desc}</span>
      </span>
    </div>
  );
}

export function AuthHighlights() {
  return (
    <>
      <AuthFeature title="Proyek dan Tugas Terorganisasi" desc="Atur antrean, prioritas, dan penugasan dalam satu alur kerja." />
      <AuthFeature title="Review dan Persetujuan Terdokumentasi" desc="Lacak revisi, versi file, dan keputusan persetujuan dengan jelas." />
      <AuthFeature title="Pembaruan Lintas Perangkat" desc="Pantau perubahan status pekerjaan dari berbagai perangkat." />
    </>
  );
}

export function FieldError({ msg }: { msg: string | null }) {
  if (!msg) return null;
  return <div role="alert" className="rounded-xl border border-rose-200 bg-rose-50 px-2.5 py-1.5 text-xs font-medium text-rose-800">{msg}</div>;
}

export const inputCls = "input w-full px-3 py-2 text-sm";
export const btnPrimary = "btn-primary w-full rounded-xl px-3 py-2.5 text-sm font-semibold text-white disabled:opacity-50";
