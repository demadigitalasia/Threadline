"use client";

import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { useReadyStore } from "@/lib/store-context";
import { formatJobCode, formatWIB, type FinanceMonthlyJob, type FinancePaymentAuditRow, type FinancePaymentHistoryRow, type FinanceUnpaidJob, type FreelancerPaymentSchedule } from "@/lib/domain";
import { Empty, Select, type Toast } from "./threadline-ui";

const money = (amount: number) => `Rp${amount.toLocaleString("id-ID")}`;

function jakartaMonth(): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Jakarta", year: "numeric", month: "2-digit",
  }).formatToParts(new Date());
  return `${parts.find((part) => part.type === "year")?.value}-${parts.find((part) => part.type === "month")?.value}`;
}

function jakartaDateTimeInput(): string {
  const formatted = new Intl.DateTimeFormat("sv-SE", {
    timeZone: "Asia/Jakarta", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).format(new Date());
  return formatted.replace(" ", "T");
}

function jakartaInputToIso(value: string): string {
  return new Date(`${value}:00+07:00`).toISOString();
}

function csvCell(value: string | number): string {
  const raw = String(value);
  const safe = typeof value === "string" && /^[\t\r=+@-]/.test(raw) ? `'${raw}` : raw;
  return `"${safe.replaceAll('"', '""')}"`;
}

function auditDescription(event: FinancePaymentAuditRow): string {
  if (event.eventType === "bank_details_viewed") return `Rekening bank ${event.targetName} dibuka`;
  if (event.eventType === "payment_proof_viewed") return `Bukti transfer ${event.paymentRecordId ?? ""} dibuka untuk ${event.targetName}`;
  if (event.eventType === "payment_voided") return `Pencatatan ${event.paymentRecordId ?? ""} dibatalkan: ${String(event.details.reason ?? "")}`;
  if (event.eventType === "payment_schedule_updated") {
    const after = event.details.after as { payout_frequency?: string } | undefined;
    const schedule = { per_job: "Per job", daily: "Harian", weekly: "Mingguan", monthly: "Bulanan" }[after?.payout_frequency ?? ""] ?? "jadwal";
    return `Jadwal pembayaran ${event.targetName} diubah menjadi ${schedule}`;
  }
  return `Transfer ${String(event.details.bank_reference ?? "")} dicatat untuk ${event.targetName} (${money(Number(event.details.amount ?? 0))})`;
}

export function FinancePayments({ onToast }: { onToast: Toast }) {
  const {
    data, financeMonthlyPaymentReport, financeMonthlyJobs, financePaymentHistory, financePaymentAuditLog, financeUnpaidJobs,
    recordFreelancerPayment, voidFreelancerPayment, openFinancePaymentProof,
    getFreelancerBankAccount, setFreelancerPaymentSchedule,
  } = useReadyStore();
  const [month, setMonth] = useState(jakartaMonth);
  const [report, setReport] = useState<Awaited<ReturnType<typeof financeMonthlyPaymentReport>>["rows"]>([]);
  const [reportError, setReportError] = useState("");
  const [reportLoading, setReportLoading] = useState(true);
  const [history, setHistory] = useState<FinancePaymentHistoryRow[]>([]);
  const [historyError, setHistoryError] = useState("");
  const [historyLoading, setHistoryLoading] = useState(true);
  const [historyTotal, setHistoryTotal] = useState(0);
  const [monthlyJobs, setMonthlyJobs] = useState<FinanceMonthlyJob[]>([]);
  const [monthlyJobsTotal, setMonthlyJobsTotal] = useState(0);
  const [monthlyJobsError, setMonthlyJobsError] = useState("");
  const [monthlyJobsLoading, setMonthlyJobsLoading] = useState(false);
  const [auditLog, setAuditLog] = useState<FinancePaymentAuditRow[]>([]);
  const [auditTotal, setAuditTotal] = useState(0);
  const [auditError, setAuditError] = useState("");
  const [auditLoading, setAuditLoading] = useState(true);
  const [refreshKey, setRefreshKey] = useState(0);
  const [selectedProfileId, setSelectedProfileId] = useState("");
  const paymentDetailsRef = useRef<HTMLElement>(null);
  const [unpaidJobs, setUnpaidJobs] = useState<FinanceUnpaidJob[]>([]);
  const [unpaidTotal, setUnpaidTotal] = useState(0);
  const [unpaidError, setUnpaidError] = useState("");
  const [unpaidLoading, setUnpaidLoading] = useState(false);
  const [allocations, setAllocations] = useState<Record<string, number>>({});
  const [paidAt, setPaidAt] = useState(jakartaDateTimeInput);
  const [bankReference, setBankReference] = useState("");
  const [note, setNote] = useState("");
  const [proof, setProof] = useState<File | null>(null);
  const [recording, setRecording] = useState(false);
  const [scheduleDraft, setScheduleDraft] = useState<Record<string, FreelancerPaymentSchedule>>({});
  const [savingSchedule, setSavingSchedule] = useState("");
  const [bankDetails, setBankDetails] = useState<Record<string, { bankName: string; accountNumber: string; accountHolder: string; token: string }>>({});
  const [revealingBank, setRevealingBank] = useState("");
  const [proofUrls, setProofUrls] = useState<Record<string, string>>({});
  const [openingProof, setOpeningProof] = useState("");
  const [voidTarget, setVoidTarget] = useState("");
  const [voidReason, setVoidReason] = useState("");
  const [voiding, setVoiding] = useState(false);
  const [auditRefreshKey, setAuditRefreshKey] = useState(0);

  useEffect(() => {
    let current = true;
    setReportLoading(true);
    setReportError("");
    void financeMonthlyPaymentReport(month).then((result) => {
      if (!current) return;
      setReport(result.rows);
      setReportError(result.ok ? "" : result.error ?? "Laporan gagal dimuat.");
      setSelectedProfileId((selected) => result.rows.some((row) => row.profileId === selected) ? selected : (result.rows[0]?.profileId ?? ""));
    }).catch(() => {
      if (current) setReportError("Koneksi terputus. Laporan bulanan belum dapat dimuat.");
    }).finally(() => { if (current) setReportLoading(false); });
    return () => { current = false; };
  }, [financeMonthlyPaymentReport, month, refreshKey]);

  useEffect(() => {
    let current = true;
    setHistoryLoading(true);
    setHistoryError("");
    setHistory([]);
    setHistoryTotal(0);
    void financePaymentHistory(month, 50, 0).then((result) => {
      if (!current) return;
      setHistory(result.rows);
      setHistoryTotal(Number(result.rows[0]?.totalRows ?? 0));
      setHistoryError(result.ok ? "" : result.error ?? "Histori pembayaran gagal dimuat.");
    }).catch(() => {
      if (current) setHistoryError("Koneksi terputus. Histori pembayaran belum dapat dimuat.");
    }).finally(() => { if (current) setHistoryLoading(false); });
    return () => { current = false; };
  }, [financePaymentHistory, month, refreshKey]);

  useEffect(() => {
    if (!selectedProfileId) {
      setMonthlyJobs([]);
      setMonthlyJobsTotal(0);
      return;
    }
    let current = true;
    setMonthlyJobsLoading(true);
    setMonthlyJobsError("");
    setMonthlyJobs([]);
    setMonthlyJobsTotal(0);
    void financeMonthlyJobs(month, selectedProfileId, 50, 0).then((result) => {
      if (!current) return;
      setMonthlyJobs(result.rows);
      setMonthlyJobsTotal(Number(result.rows[0]?.totalRows ?? 0));
      setMonthlyJobsError(result.ok ? "" : result.error ?? "Rincian job bulanan gagal dimuat.");
    }).catch(() => {
      if (current) setMonthlyJobsError("Koneksi terputus. Rincian job bulanan belum dapat dimuat.");
    }).finally(() => { if (current) setMonthlyJobsLoading(false); });
    return () => { current = false; };
  }, [financeMonthlyJobs, month, selectedProfileId, refreshKey]);

  useEffect(() => {
    let current = true;
    setAuditLoading(true);
    setAuditError("");
    setAuditLog([]);
    setAuditTotal(0);
    void financePaymentAuditLog(month, 100, 0).then((result) => {
      if (!current) return;
      setAuditLog(result.rows);
      setAuditTotal(Number(result.rows[0]?.totalRows ?? 0));
      setAuditError(result.ok ? "" : result.error ?? "Log audit pembayaran gagal dimuat.");
    }).catch(() => {
      if (current) setAuditError("Koneksi terputus. Log audit pembayaran belum dapat dimuat.");
    }).finally(() => { if (current) setAuditLoading(false); });
    return () => { current = false; };
  }, [financePaymentAuditLog, month, refreshKey, auditRefreshKey]);

  useEffect(() => {
    if (!selectedProfileId) {
      setUnpaidJobs([]);
      setUnpaidTotal(0);
      return;
    }
    let current = true;
    setUnpaidLoading(true);
    setUnpaidError("");
    setAllocations({});
    void financeUnpaidJobs(selectedProfileId, 50, 0).then((result) => {
      if (!current) return;
      setUnpaidJobs(result.rows);
      setUnpaidTotal(Number(result.rows[0]?.totalRows ?? 0));
      setUnpaidError(result.ok ? "" : result.error ?? "Rincian sisa fee gagal dimuat.");
    }).catch(() => {
      if (current) setUnpaidError("Koneksi terputus. Rincian sisa fee belum dapat dimuat.");
    }).finally(() => { if (current) setUnpaidLoading(false); });
    return () => { current = false; };
  }, [financeUnpaidJobs, selectedProfileId, refreshKey]);

  const total = useMemo(() => report.reduce((sum, row) => sum + row.earnedThisMonth, 0), [report]);
  const paidTotal = useMemo(() => report.reduce((sum, row) => sum + row.paidThisMonth, 0), [report]);
  const outstandingTotal = useMemo(() => report.reduce((sum, row) => sum + row.closingBalance, 0), [report]);
  const activeSetting = data.freelancerPaymentSettings.find((setting) => setting.profileId === selectedProfileId);

  const showPaymentDetails = (profileId: string) => {
    setSelectedProfileId(profileId);
    paymentDetailsRef.current?.scrollIntoView({ behavior: "smooth", block: "start" });
  };
  const selectedAllocations = unpaidJobs
    .filter((job) => (allocations[job.jobId] ?? 0) > 0)
    .map((job) => ({ jobId: job.jobId, amount: allocations[job.jobId] }));
  const transferTotal = selectedAllocations.reduce((sum, allocation) => sum + allocation.amount, 0);

  const saveSchedule = async (profileId: string) => {
    const setting = data.freelancerPaymentSettings.find((row) => row.profileId === profileId);
    const schedule = scheduleDraft[profileId] ?? setting?.schedule;
    if (!schedule || schedule === setting?.schedule) return;
    setSavingSchedule(profileId);
    try {
      const result = await setFreelancerPaymentSchedule(profileId, schedule);
      onToast(result.ok ? "Jadwal pembayaran berhasil disimpan." : result.error ?? "Jadwal pembayaran gagal disimpan.");
      if (result.ok) setRefreshKey((key) => key + 1);
    } catch {
      onToast("Koneksi terputus. Jadwal pembayaran belum tersimpan.");
    } finally {
      setSavingSchedule("");
    }
  };

  const revealBank = async (profileId: string) => {
    setRevealingBank(profileId);
    try {
      const result = await getFreelancerBankAccount(profileId);
      if (!result.ok || !result.account) {
        onToast(result.error ?? "Rekening bank belum tersedia.");
      } else {
        const token = globalThis.crypto.randomUUID();
        setBankDetails((current) => ({ ...current, [profileId]: { ...result.account!, token } }));
        setTimeout(() => setBankDetails((current) => {
          if (current[profileId]?.token !== token) return current;
          const next = { ...current };
          delete next[profileId];
          return next;
        }), 60_000);
        setAuditRefreshKey((key) => key + 1);
      }
    } catch {
      onToast("Koneksi terputus. Rekening belum dapat dibuka.");
    } finally {
      setRevealingBank("");
    }
  };

  const addMoreUnpaid = async () => {
    if (!selectedProfileId || unpaidJobs.length >= unpaidTotal) return;
    const offset = unpaidJobs.length;
    setUnpaidLoading(true);
    const result = await financeUnpaidJobs(selectedProfileId, 50, offset);
    if (result.ok) {
      setUnpaidJobs((rows) => [...rows, ...result.rows]);
    } else {
      setUnpaidError(result.error ?? "Rincian berikutnya gagal dimuat.");
    }
    setUnpaidLoading(false);
  };

  const addMoreHistory = async () => {
    if (history.length >= historyTotal) return;
    setHistoryLoading(true);
    const result = await financePaymentHistory(month, 50, history.length);
    if (result.ok) setHistory((rows) => [...rows, ...result.rows]);
    else setHistoryError(result.error ?? "Histori berikutnya gagal dimuat.");
    setHistoryLoading(false);
  };

  const addMoreMonthlyJobs = async () => {
    if (!selectedProfileId || monthlyJobs.length >= monthlyJobsTotal) return;
    setMonthlyJobsLoading(true);
    const result = await financeMonthlyJobs(month, selectedProfileId, 50, monthlyJobs.length);
    if (result.ok) setMonthlyJobs((rows) => [...rows, ...result.rows]);
    else setMonthlyJobsError(result.error ?? "Rincian job berikutnya gagal dimuat.");
    setMonthlyJobsLoading(false);
  };

  const addMoreAudit = async () => {
    if (auditLog.length >= auditTotal) return;
    setAuditLoading(true);
    const result = await financePaymentAuditLog(month, 100, auditLog.length);
    if (result.ok) setAuditLog((rows) => [...rows, ...result.rows]);
    else setAuditError(result.error ?? "Log audit berikutnya gagal dimuat.");
    setAuditLoading(false);
  };

  const submitPayment = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!selectedProfileId || !proof || selectedAllocations.length === 0) return;
    setRecording(true);
    try {
      const result = await recordFreelancerPayment({
        recipientProfileId: selectedProfileId,
        paidAt: jakartaInputToIso(paidAt),
        bankReference,
        note,
        allocations: selectedAllocations,
        proof,
      });
      if (!result.ok) {
        onToast(result.error ?? "Pembayaran gagal dicatat.");
        return;
      }
      onToast(`Pembayaran ${money(transferTotal)} berhasil dicatat.`);
      setBankReference("");
      setNote("");
      setProof(null);
      setPaidAt(jakartaDateTimeInput());
      setAllocations({});
      setRefreshKey((key) => key + 1);
    } catch {
      onToast("Koneksi terputus. Pembayaran belum dapat dicatat.");
    } finally {
      setRecording(false);
    }
  };

  const voidPayment = async (paymentId: string) => {
    setVoiding(true);
    try {
      const result = await voidFreelancerPayment(paymentId, voidReason);
      onToast(result.ok ? "Pencatatan pembayaran dibatalkan dan masuk histori audit." : result.error ?? "Pembayaran gagal dibatalkan.");
      if (result.ok) {
        setVoidTarget("");
        setVoidReason("");
        setAuditRefreshKey((key) => key + 1);
      }
    } catch {
      onToast("Koneksi terputus. Pembayaran belum berubah.");
    } finally {
      setVoiding(false);
    }
  };

  const showProof = async (paymentId: string) => {
    setOpeningProof(paymentId);
    try {
      const result = await openFinancePaymentProof(paymentId);
      if (result.ok && result.url) {
        setProofUrls((current) => ({ ...current, [paymentId]: result.url! }));
        setTimeout(() => setProofUrls((current) => {
          if (current[paymentId] !== result.url) return current;
          const next = { ...current };
          delete next[paymentId];
          return next;
        }), 240_000);
        setRefreshKey((key) => key + 1);
      }
      else onToast(result.error ?? "Bukti pembayaran gagal dibuka.");
    } catch {
      onToast("Koneksi terputus. Bukti pembayaran belum dapat dibuka.");
    } finally {
      setOpeningProof("");
    }
  };

  const downloadCsv = () => {
    const lines = [
      ["Freelancer", "Saldo awal", "Fee timbul bulan ini", "Transfer bersih bulan ini", "Saldo akhir", "Job selesai bulan ini"].map(csvCell).join(","),
      ...report.map((row) => [row.profileName, row.openingBalance, row.earnedThisMonth, row.paidThisMonth, row.closingBalance, row.jobsFinishedThisMonth].map(csvCell).join(",")),
    ];
    const blob = new Blob([`\uFEFF${lines.join("\r\n")}`], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = `rekap-pembayaran-${month}.csv`;
    anchor.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="space-y-3">
      <div className="auth-side relative overflow-hidden rounded-3xl p-5 text-white sm:p-6">
        <div className="relative flex flex-wrap items-end justify-between gap-4">
          <div>
            <h2 className="text-xl font-extrabold tracking-tight sm:text-2xl">Rekap dan pembayaran freelancer</h2>
            <p className="mt-1 max-w-2xl text-sm leading-5 text-white/75">Catat transfer aktual, alokasikan ke job Finished, dan telusuri saldo kewajiban per bulan.</p>
          </div>
          <label className="text-xs font-bold text-white/80">
            Bulan laporan
            <input type="month" value={month} onChange={(event) => setMonth(event.target.value)} className="input mt-1 block rounded-xl px-3 py-2 text-sm font-semibold text-zinc-900" />
          </label>
        </div>
      </div>

      <section className="glass-card p-4 sm:p-5" aria-labelledby="monthly-report-title">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <h3 id="monthly-report-title" className="text-sm font-extrabold">Laporan bulanan</h3>
            <p className="mt-1 text-xs leading-5 text-zinc-500">Fee mengikuti tanggal job menjadi Finished; transfer bersih mengikuti tanggal transfer dan pembatalan pencatatan. Semua tanggal dibaca dalam WIB.</p>
          </div>
          <button type="button" onClick={downloadCsv} disabled={reportLoading || report.length === 0} className="rounded-xl border border-zinc-200 bg-white px-3 py-2 text-xs font-bold text-zinc-700 disabled:opacity-50">Unduh CSV</button>
        </div>
        <div className="mt-3 grid grid-cols-1 gap-2 sm:grid-cols-3">
          <div className="rounded-2xl bg-indigo-50/80 p-3"><div className="text-[10px] font-bold uppercase tracking-wider text-indigo-700">Fee timbul bulan ini</div><div className="mt-1 text-lg font-extrabold tabular-nums text-indigo-950">{money(total)}</div></div>
          <div className="rounded-2xl bg-emerald-50/80 p-3"><div className="text-[10px] font-bold uppercase tracking-wider text-emerald-700">Transfer bersih bulan ini</div><div className="mt-1 text-lg font-extrabold tabular-nums text-emerald-950">{money(paidTotal)}</div></div>
          <div className="rounded-2xl bg-amber-50/80 p-3"><div className="text-[10px] font-bold uppercase tracking-wider text-amber-800">Sisa kewajiban akhir bulan</div><div className="mt-1 text-lg font-extrabold tabular-nums text-amber-950">{money(outstandingTotal)}</div></div>
        </div>
        {reportError && <div className="mt-3 rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-800">{reportError}</div>}
        {reportLoading ? <div className="py-6 text-center text-sm text-zinc-500">Memuat laporan…</div> : report.length === 0 ? <div className="mt-3"><Empty text="Belum ada freelancer yang disetujui." /></div> : (
          <div className="mt-3 overflow-x-auto rounded-2xl border border-zinc-200/80">
            <table className="min-w-[760px] w-full text-left text-xs">
              <thead className="bg-zinc-50 text-[10px] uppercase tracking-wider text-zinc-500"><tr><th className="px-3 py-2.5">Freelancer</th><th className="px-3 py-2.5 text-right">Saldo awal</th><th className="px-3 py-2.5 text-right">Fee timbul</th><th className="px-3 py-2.5 text-right">Transfer</th><th className="px-3 py-2.5 text-right">Saldo akhir</th><th className="px-3 py-2.5 text-right">Job</th><th className="px-3 py-2.5"></th></tr></thead>
              <tbody className="divide-y divide-zinc-100 bg-white/70">
                {report.map((row) => <tr key={row.profileId} className={selectedProfileId === row.profileId ? "bg-indigo-50/70" : ""}>
                  <td className="px-3 py-3 font-bold">{row.profileName}</td>
                  <td className="px-3 py-3 text-right tabular-nums">{money(row.openingBalance)}</td>
                  <td className="px-3 py-3 text-right tabular-nums">{money(row.earnedThisMonth)}</td>
                  <td className="px-3 py-3 text-right tabular-nums">{money(row.paidThisMonth)}</td>
                  <td className="px-3 py-3 text-right font-extrabold tabular-nums">{money(row.closingBalance)}</td>
                  <td className="px-3 py-3 text-right tabular-nums">{row.jobsFinishedThisMonth}</td>
                  <td className="px-3 py-3 text-right"><button type="button" onClick={() => showPaymentDetails(row.profileId)} aria-controls="payment-detail-title" aria-expanded={selectedProfileId === row.profileId} className="rounded-lg bg-indigo-100 px-2.5 py-1.5 font-bold text-indigo-800">Rincian</button></td>
                </tr>)}
              </tbody>
            </table>
          </div>
        )}
        <p className="mt-2 text-[10px] leading-4 text-zinc-400">Untuk job lama tanpa event selesai, tanggal selesai diperkirakan dari tanggal dibuat. Transfer lama di luar aplikasi perlu dicatat manual memakai tanggal transfer dan bukti aslinya agar saldo awal cocok.</p>
      </section>

      <section ref={paymentDetailsRef} className="glass-card scroll-mt-20 p-4 sm:p-5" aria-labelledby="payment-detail-title">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <h3 id="payment-detail-title" className="text-sm font-extrabold">Sisa fee dan pencatatan transfer</h3>
            <p className="mt-1 text-xs leading-5 text-zinc-500">Pilih job, masukkan nilai yang dialokasikan, lalu simpan tanggal, referensi, dan bukti transfer.</p>
          </div>
          {report.length > 0 && <Select ariaLabel="Pilih freelancer" className="w-full sm:w-64" value={selectedProfileId} onChange={setSelectedProfileId} options={report.map((row) => ({ value: row.profileId, label: row.profileName }))} />}
        </div>

        {selectedProfileId && <div className="mt-3 space-y-3">
          {activeSetting && <div className="grid gap-3 rounded-2xl border border-zinc-200/80 bg-white/60 p-3 md:grid-cols-[minmax(200px,1fr)_minmax(180px,0.8fr)_auto] md:items-center">
            <div className="min-w-0">
              <div className="text-xs font-bold">Rekening penerima · {activeSetting.profileName}</div>
              <div className="mt-1 text-xs text-zinc-500">{activeSetting.bankName ? `${activeSetting.bankName} · ${activeSetting.accountHolder ?? ""} · ${activeSetting.accountNumber ?? ""}` : "Rekening bank belum diisi"}</div>
              {bankDetails[selectedProfileId] && <div className="mt-1 break-all rounded-lg bg-amber-50 px-2 py-1.5 text-xs font-semibold text-amber-950">{bankDetails[selectedProfileId].bankName} · {bankDetails[selectedProfileId].accountHolder} · {bankDetails[selectedProfileId].accountNumber}</div>}
            </div>
            <label className="text-[10px] font-bold uppercase tracking-wider text-zinc-400">Jadwal pembayaran
              <Select ariaLabel={`Jadwal pembayaran ${activeSetting.profileName}`} className="mt-1" value={scheduleDraft[selectedProfileId] ?? activeSetting.schedule} onChange={(value) => setScheduleDraft((current) => ({ ...current, [selectedProfileId]: value as FreelancerPaymentSchedule }))} options={[
                { value: "per_job", label: "Per job" }, { value: "daily", label: "Harian" }, { value: "weekly", label: "Mingguan" }, { value: "monthly", label: "Bulanan" },
              ]} />
            </label>
            <div className="flex flex-wrap gap-2">
              <button type="button" onClick={() => void revealBank(selectedProfileId)} disabled={revealingBank === selectedProfileId || !activeSetting.bankName} className="rounded-xl border border-zinc-200 bg-white px-3 py-2 text-xs font-bold text-zinc-700 disabled:opacity-50">{revealingBank === selectedProfileId ? "Membuka…" : "Lihat rekening"}</button>
              <button type="button" onClick={() => void saveSchedule(selectedProfileId)} disabled={savingSchedule === selectedProfileId || (scheduleDraft[selectedProfileId] ?? activeSetting.schedule) === activeSetting.schedule} className="btn-primary rounded-xl px-3 py-2 text-xs font-bold text-white disabled:opacity-50">{savingSchedule === selectedProfileId ? "Menyimpan…" : "Simpan jadwal"}</button>
            </div>
          </div>}

          <div className="rounded-2xl border border-zinc-200/80 bg-white/60 p-3">
            <div className="flex flex-wrap items-start justify-between gap-2"><div><div className="text-xs font-extrabold">Job Finished bulan {month}</div><p className="mt-1 text-[10px] text-zinc-500">Mencakup job lunas maupun yang masih memiliki saldo.</p></div><span className="text-[10px] font-bold text-zinc-500">{monthlyJobsTotal} job</span></div>
            {monthlyJobsError && <div className="mt-2 text-xs text-rose-700">{monthlyJobsError}</div>}
            {monthlyJobsLoading && monthlyJobs.length === 0 ? <p className="py-4 text-center text-xs text-zinc-500">Memuat rincian bulanan…</p> : monthlyJobs.length === 0 ? <p className="py-4 text-center text-xs text-zinc-500">Tidak ada job Finished pada bulan ini.</p> : <div className="mt-2 overflow-x-auto rounded-xl border border-zinc-100"><table className="min-w-[620px] w-full text-left text-[11px]"><thead className="bg-zinc-50 text-[10px] uppercase tracking-wider text-zinc-500"><tr><th className="px-2.5 py-2">Job / Tim</th><th className="px-2.5 py-2">Finished</th><th className="px-2.5 py-2 text-right">Fee</th><th className="px-2.5 py-2 text-right">Terbayar</th><th className="px-2.5 py-2 text-right">Sisa</th></tr></thead><tbody className="divide-y divide-zinc-100">{monthlyJobs.map((job) => <tr key={job.jobId}><td className="px-2.5 py-2"><b className="font-mono">{formatJobCode(job.jobId)}</b><span className="ml-1 text-zinc-500">{job.teamName} · {job.jobType}</span></td><td className="px-2.5 py-2 whitespace-nowrap text-zinc-500">{formatWIB(job.finishedAt)}</td><td className="px-2.5 py-2 text-right tabular-nums">{money(job.earnedFee)}</td><td className="px-2.5 py-2 text-right tabular-nums">{money(job.paidAmount)}</td><td className="px-2.5 py-2 text-right font-bold tabular-nums">{money(job.dueAmount)}</td></tr>)}</tbody></table></div>}
            {monthlyJobs.length < monthlyJobsTotal && <div className="mt-2 text-center"><button type="button" onClick={() => void addMoreMonthlyJobs()} disabled={monthlyJobsLoading} className="rounded-lg border border-zinc-200 bg-white px-3 py-1.5 text-[10px] font-bold disabled:opacity-50">Muat job lainnya</button></div>}
          </div>

          {unpaidError && <div className="rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-800">{unpaidError}</div>}
          <div className="overflow-x-auto rounded-2xl border border-zinc-200/80">
            <table className="min-w-[720px] w-full text-left text-xs">
              <thead className="bg-zinc-50 text-[10px] uppercase tracking-wider text-zinc-500"><tr><th className="px-3 py-2.5">Pilih / Job</th><th className="px-3 py-2.5">Tanggal Finished</th><th className="px-3 py-2.5 text-right">Fee</th><th className="px-3 py-2.5 text-right">Terbayar</th><th className="px-3 py-2.5 text-right">Sisa</th><th className="px-3 py-2.5 text-right">Alokasi transfer</th></tr></thead>
              <tbody className="divide-y divide-zinc-100 bg-white/70">
                {unpaidJobs.map((job) => {
                  const amount = allocations[job.jobId] ?? 0;
                  return <tr key={job.jobId}>
                    <td className="px-3 py-3"><label className="flex items-center gap-2"><input type="checkbox" checked={amount > 0} onChange={(event) => setAllocations((current) => ({ ...current, [job.jobId]: event.target.checked ? job.dueAmount : 0 }))} className="accent-indigo-600" /><span><b className="font-mono">{formatJobCode(job.jobId)}</b><span className="ml-1 text-zinc-500">{job.teamName} · {job.jobType}</span></span></label></td>
                    <td className="px-3 py-3 whitespace-nowrap text-zinc-500">{formatWIB(job.finishedAt)}</td>
                    <td className="px-3 py-3 text-right tabular-nums">{money(job.earnedFee)}</td>
                    <td className="px-3 py-3 text-right tabular-nums">{money(job.paidAmount)}</td>
                    <td className="px-3 py-3 text-right font-bold tabular-nums">{money(job.dueAmount)}</td>
                    <td className="px-3 py-3 text-right"><input aria-label={`Alokasi untuk ${formatJobCode(job.jobId)}`} className="input w-32 px-2 py-1.5 text-right text-xs tabular-nums" type="number" min={0} max={job.dueAmount} step={1} disabled={amount <= 0} value={amount > 0 ? amount : ""} onChange={(event) => setAllocations((current) => ({ ...current, [job.jobId]: Math.max(0, Math.min(job.dueAmount, Number(event.target.value) || 0)) }))} placeholder="Rp" /></td>
                  </tr>;
                })}
                {!unpaidLoading && unpaidJobs.length === 0 && <tr><td colSpan={6} className="px-3 py-6 text-center text-zinc-500">Tidak ada sisa fee untuk freelancer ini.</td></tr>}
              </tbody>
            </table>
          </div>
          {unpaidLoading && <p className="text-center text-xs text-zinc-500">Memuat rincian job…</p>}
          {unpaidJobs.length < unpaidTotal && <div className="text-center"><button type="button" onClick={() => void addMoreUnpaid()} disabled={unpaidLoading} className="rounded-xl border border-zinc-200 bg-white px-3 py-2 text-xs font-bold text-zinc-700 disabled:opacity-50">Muat job lainnya ({unpaidJobs.length}/{unpaidTotal})</button></div>}

          <form onSubmit={(event) => void submitPayment(event)} className="grid gap-3 rounded-2xl border border-indigo-100 bg-indigo-50/40 p-3 sm:grid-cols-2">
            <div className="sm:col-span-2 flex flex-wrap items-center justify-between gap-2"><div className="text-sm font-extrabold">Catat transfer manual</div><div className="text-sm font-extrabold tabular-nums text-indigo-950">Total alokasi: {money(transferTotal)}</div></div>
            <label className="text-xs font-bold text-zinc-600">Tanggal dan waktu transfer (WIB)<input type="datetime-local" required value={paidAt} onChange={(event) => setPaidAt(event.target.value)} className="input mt-1 block w-full px-3 py-2 text-sm" /></label>
            <label className="text-xs font-bold text-zinc-600">Referensi transfer<input required maxLength={120} value={bankReference} onChange={(event) => setBankReference(event.target.value)} className="input mt-1 block w-full px-3 py-2 text-sm" placeholder="Nomor referensi / berita transfer" /></label>
            <label className="text-xs font-bold text-zinc-600">Bukti transfer · PDF / gambar, maks. 10 MB<input key={proof ? "selected-proof" : "empty-proof"} required type="file" accept="application/pdf,image/jpeg,image/png,image/webp,.pdf,.jpg,.jpeg,.png,.webp" onChange={(event) => setProof(event.target.files?.[0] ?? null)} className="mt-1 block w-full text-xs text-zinc-600 file:mr-2 file:rounded-lg file:border-0 file:bg-white file:px-3 file:py-2 file:text-xs file:font-bold" /></label>
            <label className="text-xs font-bold text-zinc-600">Catatan (opsional)<input maxLength={1000} value={note} onChange={(event) => setNote(event.target.value)} className="input mt-1 block w-full px-3 py-2 text-sm" placeholder="Keterangan tambahan" /></label>
            <div className="sm:col-span-2 flex flex-wrap items-center justify-between gap-2"><p className="text-[10px] leading-4 text-zinc-500">Nomor referensi duplikat ditolak. Job yang sama tidak bisa dibayar melebihi fee yang disetujui.</p><button type="submit" disabled={recording || !proof || !bankReference.trim() || selectedAllocations.length === 0 || transferTotal <= 0} className="btn-primary rounded-xl px-4 py-2.5 text-xs font-extrabold text-white disabled:opacity-50">{recording ? "Menyimpan transfer…" : "Simpan pembayaran"}</button></div>
          </form>
        </div>}
      </section>

      <section className="glass-card p-4 sm:p-5" aria-labelledby="payment-history-title">
        <div className="flex flex-wrap items-start justify-between gap-2"><div><h3 id="payment-history-title" className="text-sm font-extrabold">Histori transfer · {month}</h3><p className="mt-1 text-xs text-zinc-500">Pencatatan yang dibatalkan tetap disimpan dan ditandai di histori.</p></div><span className="rounded-full bg-zinc-100 px-2.5 py-1 text-[11px] font-bold text-zinc-600">{historyTotal} transaksi</span></div>
        {historyError && <div className="mt-3 rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-800">{historyError}</div>}
        <div className="mt-3 space-y-2">
          {history.map((row) => <PaymentHistoryItem key={row.paymentId} row={row} proofUrl={proofUrls[row.paymentId]} openingProof={openingProof === row.paymentId} onOpenProof={() => void showProof(row.paymentId)} voidTarget={voidTarget === row.paymentId} voidReason={voidReason} onVoidReason={setVoidReason} onStartVoid={() => { setVoidTarget(row.paymentId); setVoidReason(""); }} onCancelVoid={() => setVoidTarget("")} onConfirmVoid={() => void voidPayment(row.paymentId)} voiding={voiding} />)}
          {!historyLoading && history.length === 0 && <Empty text="Belum ada transfer tercatat pada bulan ini." />}
          {historyLoading && <p className="py-4 text-center text-xs text-zinc-500">Memuat histori…</p>}
        </div>
        {history.length < historyTotal && <div className="mt-3 text-center"><button type="button" onClick={() => void addMoreHistory()} disabled={historyLoading} className="rounded-xl border border-zinc-200 bg-white px-3 py-2 text-xs font-bold disabled:opacity-50">Muat transaksi berikutnya</button></div>}
      </section>

      <section className="glass-card p-4 sm:p-5" aria-labelledby="payment-audit-title">
        <div className="flex flex-wrap items-start justify-between gap-2"><div><h3 id="payment-audit-title" className="text-sm font-extrabold">Log audit pembayaran · {month}</h3><p className="mt-1 text-xs text-zinc-500">Pencatatan transfer, pembatalan, dan pembukaan rekening atau bukti.</p></div><span className="rounded-full bg-zinc-100 px-2.5 py-1 text-[11px] font-bold text-zinc-600">{auditTotal} aktivitas</span></div>
        {auditError && <div className="mt-3 rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-800">{auditError}</div>}
        <div className="mt-3 divide-y divide-zinc-100">
          {auditLog.map((event) => <div key={event.eventId} className="flex flex-wrap items-baseline gap-x-3 gap-y-1 py-2 text-xs"><time className="text-zinc-400">{formatWIB(event.createdAt)} WIB</time><span className="min-w-0 flex-1 font-medium text-zinc-700">{auditDescription(event)}</span><span className="text-zinc-500">oleh {event.actorName}</span></div>)}
          {!auditLoading && auditLog.length === 0 && !auditError && <p className="py-4 text-center text-xs text-zinc-500">Belum ada aktivitas audit pada bulan ini.</p>}
          {auditLoading && <p className="py-4 text-center text-xs text-zinc-500">Memuat log audit…</p>}
        </div>
        {auditLog.length < auditTotal && <div className="text-center"><button type="button" onClick={() => void addMoreAudit()} disabled={auditLoading} className="rounded-xl border border-zinc-200 bg-white px-3 py-2 text-xs font-bold disabled:opacity-50">Muat aktivitas berikutnya</button></div>}
      </section>

      {data.freelancerPaymentSettingsError && <p className="text-xs text-zinc-500">Pengaturan rekening dan jadwal belum dapat dimuat dari basis data.</p>}
    </div>
  );
}

function PaymentHistoryItem({
  row, proofUrl, openingProof, onOpenProof, voidTarget, voidReason, onVoidReason, onStartVoid, onCancelVoid, onConfirmVoid, voiding,
}: {
  row: FinancePaymentHistoryRow;
  proofUrl?: string;
  openingProof: boolean;
  onOpenProof: () => void;
  voidTarget: boolean;
  voidReason: string;
  onVoidReason: (value: string) => void;
  onStartVoid: () => void;
  onCancelVoid: () => void;
  onConfirmVoid: () => void;
  voiding: boolean;
}) {
  return <article className={`rounded-2xl border p-3 ${row.status === "voided" ? "border-rose-200 bg-rose-50/50" : "border-zinc-200/80 bg-white/70"}`}>
    <div className="flex flex-wrap items-start gap-2">
      <div className="min-w-0 flex-1"><div className="flex flex-wrap items-center gap-2"><span className="text-sm font-extrabold">{row.recipientName}</span><span className={`rounded-full px-2 py-0.5 text-[10px] font-bold ${row.status === "posted" ? "bg-emerald-100 text-emerald-800" : "bg-rose-100 text-rose-800"}`}>{row.status === "posted" ? "Tercatat" : "Dibatalkan"}</span></div><div className="mt-1 text-[11px] text-zinc-500">{formatWIB(row.paidAt)} WIB · Referensi: <b className="text-zinc-700">{row.bankReference}</b> · Dicatat oleh {row.recordedBy}</div>{row.bankName && <div className="mt-1 text-[11px] text-zinc-400">Rekening saat dicatat: {row.bankName} · {row.accountHolder ?? ""} · •••• {row.accountNumberLast4 ?? "----"}</div>}</div>
      <div className="text-right text-sm font-extrabold tabular-nums">{money(row.amount)}</div>
    </div>
    <div className="mt-2 flex flex-wrap items-center gap-2 text-xs">
      <span className="text-zinc-500">{row.allocations.length} alokasi:</span>
      {row.allocations.map((allocation) => <span key={allocation.jobId} className="rounded-lg bg-zinc-100 px-2 py-1 font-medium text-zinc-700">{formatJobCode(allocation.jobId)} · {allocation.teamName} · {money(allocation.amount)}</span>)}
      {row.note && <span className="text-zinc-500">Catatan: {row.note}</span>}
    </div>
    <div className="mt-2 flex flex-wrap items-center gap-2">
      {proofUrl ? <a href={proofUrl} target="_blank" rel="noreferrer" className="rounded-lg border border-zinc-200 bg-white px-2.5 py-1.5 text-xs font-bold text-indigo-700">Buka bukti</a> : <button type="button" onClick={onOpenProof} disabled={openingProof} className="rounded-lg border border-zinc-200 bg-white px-2.5 py-1.5 text-xs font-bold text-indigo-700 disabled:opacity-50">{openingProof ? "Menyiapkan bukti…" : "Lihat bukti"}</button>}
      {row.status === "posted" && !voidTarget && <button type="button" onClick={onStartVoid} className="rounded-lg px-2.5 py-1.5 text-xs font-bold text-rose-700 hover:bg-rose-50">Batalkan pencatatan</button>}
      {row.status === "voided" && <span className="text-[11px] text-rose-700">Dibatalkan {row.voidedAt ? formatWIB(row.voidedAt) : ""} oleh {row.voidedBy ?? "akun nonaktif"}: {row.voidReason}</span>}
    </div>
    {voidTarget && <div className="mt-2 flex flex-wrap gap-2"><input aria-label="Alasan pembatalan" maxLength={1000} value={voidReason} onChange={(event) => onVoidReason(event.target.value)} className="input min-w-48 flex-1 px-3 py-2 text-xs" placeholder="Alasan wajib untuk audit" /><button type="button" onClick={onConfirmVoid} disabled={voiding || !voidReason.trim()} className="rounded-xl bg-rose-600 px-3 py-2 text-xs font-bold text-white disabled:opacity-50">{voiding ? "Membatalkan…" : "Konfirmasi pembatalan"}</button><button type="button" onClick={onCancelVoid} disabled={voiding} className="rounded-xl border border-zinc-200 bg-white px-3 py-2 text-xs font-bold">Urungkan</button></div>}
  </article>;
}
