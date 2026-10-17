"use client";

import { useEffect, useState } from "react";
import { useNow } from "./threadline-ui";
import { Arsip, Dashboard, FreelancerAvailabilityNotifier, Intake } from "./panels";
import { ChatPanel, Rekap } from "./social";
import { AkunPanel, PengaturanPanel } from "./account";
import { SuperAdminUsersPanel } from "./super-admin-users";
import { FreelancerRegistrationsPanel } from "./freelancer-registrations";
import type { NavTab } from "./app-shell";

export function SectionView({ tab }: { tab: NavTab }) {
  const [toast, setToast] = useState<string | null>(null);
  const now = useNow();

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), 3500);
    return () => clearTimeout(t);
  }, [toast]);

  return (
    <>
      <FreelancerAvailabilityNotifier onToast={setToast} />
      {tab === "dashboard" && <Dashboard onToast={setToast} now={now} />}
      {tab === "intake" && <Intake onToast={setToast} now={now} />}
      {tab === "arsip" && <Arsip onToast={setToast} now={now} />}
      {tab === "chat" && <ChatPanel onToast={setToast} />}
      {tab === "rekap" && <Rekap onToast={setToast} />}
      {tab === "akun" && <AkunPanel onToast={setToast} />}
      {tab === "pengaturan" && <PengaturanPanel onToast={setToast} />}
      {tab === "pengguna" && <SuperAdminUsersPanel onToast={setToast} />}
      {tab === "pendaftaran" && <FreelancerRegistrationsPanel onToast={setToast} />}
      {toast && (
        <div className="fixed bottom-4 left-1/2 z-30 -translate-x-1/2 rounded-full bg-zinc-900 px-4 py-2 text-sm text-white shadow-xl">
          {toast}
        </div>
      )}
    </>
  );
}
