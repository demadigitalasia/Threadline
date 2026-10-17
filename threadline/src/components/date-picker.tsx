"use client";

import { createPortal } from "react-dom";
import { useEffect, useLayoutEffect, useRef, useState } from "react";

type DatePickerProps = {
  id: string;
  value: string;
  onChange: (value: string) => void;
  withTime?: boolean;
  ariaLabel: string;
  placeholder?: string;
};

type PickerPosition = { top: number; left: number; maxHeight: number };

const pad = (value: number) => String(value).padStart(2, "0");
const dateFormatter = new Intl.DateTimeFormat("id-ID", { day: "2-digit", month: "short", year: "numeric" });
const monthFormatter = new Intl.DateTimeFormat("id-ID", { month: "long", year: "numeric" });
const weekdayFormatter = new Intl.DateTimeFormat("id-ID", { weekday: "short" });
const weekdays = Array.from({ length: 7 }, (_, index) => weekdayFormatter.format(new Date(2024, 0, 1 + index)));

function parseValue(value: string, withTime: boolean): Date | null {
  const match = value.match(/^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?$/);
  if (!match) return null;
  const [, yearText, monthText, dayText, hourText, minuteText] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = withTime ? Number(hourText ?? 0) : 0;
  const minute = withTime ? Number(minuteText ?? 0) : 0;
  const date = new Date(year, month - 1, day, hour, minute);
  if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day) return null;
  return date;
}

function serializeDate(date: Date, withTime: boolean) {
  const day = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  return withTime ? `${day}T${pad(date.getHours())}:${pad(date.getMinutes())}` : day;
}

function displayValue(date: Date, withTime: boolean) {
  const day = dateFormatter.format(date);
  return withTime ? `${day}, ${pad(date.getHours())}.${pad(date.getMinutes())}` : day;
}

function calendarPosition(anchor: DOMRect, withTime: boolean): PickerPosition {
  const width = Math.min(336, window.innerWidth - 24);
  const estimatedHeight = withTime ? 430 : 355;
  const below = Math.max(0, window.innerHeight - anchor.bottom - 12);
  const above = Math.max(0, anchor.top - 12);
  const openAbove = below < estimatedHeight && above > below;
  const maxHeight = Math.max(180, Math.min(estimatedHeight, openAbove ? above : below || window.innerHeight - 24));
  const top = openAbove ? Math.max(12, anchor.top - maxHeight - 8) : Math.min(anchor.bottom + 8, window.innerHeight - maxHeight - 12);
  return {
    top,
    left: Math.max(12, Math.min(anchor.left, window.innerWidth - width - 12)),
    maxHeight,
  };
}

export function DatePicker({ id, value, onChange, withTime = false, ariaLabel, placeholder = "Pilih tanggal" }: DatePickerProps) {
  const [open, setOpen] = useState(false);
  const [view, setView] = useState(() => {
    const current = parseValue(value, withTime) ?? new Date();
    return new Date(current.getFullYear(), current.getMonth(), 1);
  });
  const [position, setPosition] = useState<PickerPosition | null>(null);
  const [hour, setHour] = useState("09");
  const [minute, setMinute] = useState("00");
  const triggerRef = useRef<HTMLButtonElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  const selected = parseValue(value, withTime);

  useLayoutEffect(() => {
    if (!open) return;
    const updatePosition = () => {
      if (triggerRef.current) setPosition(calendarPosition(triggerRef.current.getBoundingClientRect(), withTime));
    };
    const frame = window.requestAnimationFrame(updatePosition);
    window.addEventListener("resize", updatePosition);
    window.addEventListener("scroll", updatePosition, true);
    return () => {
      window.cancelAnimationFrame(frame);
      window.removeEventListener("resize", updatePosition);
      window.removeEventListener("scroll", updatePosition, true);
    };
  }, [open, withTime]);

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: MouseEvent) => {
      const target = event.target as Node;
      if (!panelRef.current?.contains(target) && !triggerRef.current?.contains(target)) setOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setOpen(false);
        triggerRef.current?.focus();
      }
    };
    document.addEventListener("mousedown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("mousedown", onPointerDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [open]);

  const openPicker = () => {
    const current = parseValue(value, withTime);
    const initial = current ?? new Date();
    setView(new Date(initial.getFullYear(), initial.getMonth(), 1));
    setHour(current ? pad(current.getHours()) : "09");
    setMinute(current ? pad(current.getMinutes()) : "00");
    setOpen((currentOpen) => !currentOpen);
  };

  const chooseDay = (base: Date) => {
    const chosenDate = new Date(base.getFullYear(), base.getMonth(), base.getDate());
    if (chosenDate.getFullYear() !== view.getFullYear() || chosenDate.getMonth() !== view.getMonth()) {
      setView(new Date(chosenDate.getFullYear(), chosenDate.getMonth(), 1));
    }
    if (!withTime) {
      onChange(serializeDate(chosenDate, false));
      setOpen(false);
      triggerRef.current?.focus();
      return;
    }
    const currentHour = Number(hour);
    const currentMinute = Number(minute);
    chosenDate.setHours(Number.isInteger(currentHour) && currentHour >= 0 && currentHour <= 23 ? currentHour : 9);
    chosenDate.setMinutes(Number.isInteger(currentMinute) && currentMinute >= 0 && currentMinute <= 59 ? currentMinute : 0);
    onChange(serializeDate(chosenDate, true));
  };

  const commitTime = (nextHour: string, nextMinute: string) => {
    if (!selected) return;
    const date = new Date(selected);
    date.setHours(Number(nextHour));
    date.setMinutes(Number(nextMinute));
    onChange(serializeDate(date, true));
  };

  const setTimePart = (part: "hour" | "minute", raw: string) => {
    const digits = raw.replace(/\D/g, "").slice(0, 2);
    const nextHour = part === "hour" ? digits : hour;
    const nextMinute = part === "minute" ? digits : minute;
    if (part === "hour") setHour(digits);
    else setMinute(digits);
    const parsedHour = Number(nextHour);
    const parsedMinute = Number(nextMinute);
    if (nextHour.length > 0 && nextMinute.length > 0 && parsedHour <= 23 && parsedMinute <= 59) {
      commitTime(pad(parsedHour), pad(parsedMinute));
    }
  };

  const normalizeTimePart = (part: "hour" | "minute") => {
    const raw = part === "hour" ? hour : minute;
    const upperLimit = part === "hour" ? 23 : 59;
    const normalized = pad(Math.min(upperLimit, Math.max(0, Number(raw) || 0)));
    const nextHour = part === "hour" ? normalized : hour;
    const nextMinute = part === "minute" ? normalized : minute;
    if (part === "hour") setHour(normalized);
    else setMinute(normalized);
    commitTime(nextHour, nextMinute);
  };

  const start = new Date(view.getFullYear(), view.getMonth(), 1);
  const mondayOffset = (start.getDay() + 6) % 7;
  const calendarStart = new Date(view.getFullYear(), view.getMonth(), 1 - mondayOffset);
  const days = Array.from({ length: 42 }, (_, index) => new Date(calendarStart.getFullYear(), calendarStart.getMonth(), calendarStart.getDate() + index));
  const today = new Date();
  const title = selected ? displayValue(selected, withTime) : placeholder;

  return (
    <>
      <button
        ref={triggerRef}
        id={id}
        type="button"
        aria-label={`${ariaLabel}${selected ? `: ${displayValue(selected, withTime)}` : ""}`}
        aria-haspopup="dialog"
        aria-expanded={open}
        onClick={openPicker}
        className="input flex w-full items-center justify-between gap-3 px-3 py-2 text-left text-sm text-zinc-800 transition focus:border-indigo-400 focus:ring-2 focus:ring-indigo-200/70"
      >
        <span className={`min-w-0 truncate ${selected ? "" : "text-zinc-400"}`}>{title}</span>
        <svg className="shrink-0 text-indigo-500" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
          <rect x="3" y="5" width="18" height="16" rx="2" /><path d="M16 3v4M8 3v4M3 10h18" />
        </svg>
      </button>
      {open && typeof document !== "undefined" && position && createPortal(
        <div
          ref={panelRef}
          role="dialog"
          aria-label={ariaLabel}
          className="fixed z-[80] flex w-[min(21rem,calc(100vw-1.5rem))] flex-col overflow-y-auto rounded-2xl border border-indigo-100 bg-white shadow-[0_24px_64px_-20px_rgba(30,27,75,0.55)] ring-1 ring-indigo-950/5"
          style={{ top: position.top, left: position.left, maxHeight: position.maxHeight }}
        >
          <div className="shrink-0 bg-gradient-to-r from-indigo-600 via-violet-600 to-fuchsia-500 px-4 py-3 text-white">
            <div className="flex items-center justify-between gap-3">
              <button type="button" onClick={() => setView(new Date(view.getFullYear(), view.getMonth() - 1, 1))} aria-label="Bulan sebelumnya" className="grid size-8 place-items-center rounded-lg text-white/85 transition hover:bg-white/15 hover:text-white">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d="m15 18-6-6 6-6" /></svg>
              </button>
              <div className="text-sm font-bold capitalize">{monthFormatter.format(view)}</div>
              <button type="button" onClick={() => setView(new Date(view.getFullYear(), view.getMonth() + 1, 1))} aria-label="Bulan berikutnya" className="grid size-8 place-items-center rounded-lg text-white/85 transition hover:bg-white/15 hover:text-white">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d="m9 18 6-6-6-6" /></svg>
              </button>
            </div>
          </div>

          <div className="p-3.5">
            <div role="grid" aria-label={monthFormatter.format(view)}>
              <div role="row" className="mb-1 grid grid-cols-7">
                {weekdays.map((weekday) => <div role="columnheader" key={weekday} className="py-1.5 text-center text-[10px] font-bold uppercase tracking-wide text-zinc-400">{weekday.slice(0, 2)}</div>)}
              </div>
              {Array.from({ length: 6 }, (_, row) => (
                <div role="row" key={row} className="grid grid-cols-7">
                  {days.slice(row * 7, row * 7 + 7).map((date) => {
                    const inMonth = date.getMonth() === view.getMonth();
                    const isSelected = Boolean(selected && date.getFullYear() === selected.getFullYear() && date.getMonth() === selected.getMonth() && date.getDate() === selected.getDate());
                    const isToday = date.getFullYear() === today.getFullYear() && date.getMonth() === today.getMonth() && date.getDate() === today.getDate();
                    return (
                      <div role="gridcell" key={serializeDate(date, false)} aria-selected={isSelected} className="grid place-items-center py-0.5">
                        <button
                          type="button"
                          aria-label={dateFormatter.format(date)}
                          aria-pressed={isSelected}
                          aria-current={isToday ? "date" : undefined}
                          onClick={() => chooseDay(date)}
                          className={`grid size-9 place-items-center rounded-xl text-xs font-semibold transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-indigo-400 ${
                            isSelected ? "bg-gradient-to-br from-indigo-600 to-violet-600 text-white shadow-md shadow-indigo-500/25" :
                            isToday ? "bg-indigo-50 text-indigo-700 ring-1 ring-inset ring-indigo-200" :
                            inMonth ? "text-zinc-700 hover:bg-indigo-50 hover:text-indigo-700" : "text-zinc-300 hover:bg-zinc-50"
                          }`}
                        >{date.getDate()}</button>
                      </div>
                    );
                  })}
                </div>
              ))}
            </div>

            {withTime && (
              <div className="mt-3 flex items-center justify-between gap-3 rounded-xl bg-gradient-to-r from-indigo-50 to-violet-50 px-3 py-2.5 ring-1 ring-inset ring-indigo-100">
                <div>
                  <div className="text-[11px] font-bold text-indigo-950">Waktu deadline</div>
                  <div className="mt-0.5 text-[10px] text-zinc-500">Zona waktu perangkat Anda</div>
                </div>
                <div className="flex items-center gap-1.5">
                  <label className="sr-only" htmlFor={`${id}-hour`}>Jam</label>
                  <input id={`${id}-hour`} inputMode="numeric" autoComplete="off" aria-label="Jam" value={hour} onChange={(event) => setTimePart("hour", event.target.value)} onBlur={() => normalizeTimePart("hour")} className="w-12 rounded-lg border border-indigo-100 bg-white px-1.5 py-1.5 text-center text-sm font-bold tabular-nums text-indigo-950 outline-none focus:border-indigo-400 focus:ring-2 focus:ring-indigo-100" />
                  <span className="font-bold text-indigo-500">:</span>
                  <label className="sr-only" htmlFor={`${id}-minute`}>Menit</label>
                  <input id={`${id}-minute`} inputMode="numeric" autoComplete="off" aria-label="Menit" value={minute} onChange={(event) => setTimePart("minute", event.target.value)} onBlur={() => normalizeTimePart("minute")} className="w-12 rounded-lg border border-indigo-100 bg-white px-1.5 py-1.5 text-center text-sm font-bold tabular-nums text-indigo-950 outline-none focus:border-indigo-400 focus:ring-2 focus:ring-indigo-100" />
                </div>
              </div>
            )}

            <div className="mt-3 flex items-center justify-between border-t border-zinc-100 pt-3">
              <button type="button" onClick={() => {
                const now = new Date();
                setView(new Date(now.getFullYear(), now.getMonth(), 1));
                if (withTime) {
                  const nextHour = pad(now.getHours());
                  const nextMinute = pad(now.getMinutes());
                  setHour(nextHour);
                  setMinute(nextMinute);
                  onChange(serializeDate(now, true));
                } else {
                  onChange(serializeDate(now, false));
                  setOpen(false);
                }
              }} className="rounded-lg px-2.5 py-1.5 text-xs font-bold text-indigo-600 transition hover:bg-indigo-50">Hari ini</button>
              <div className="flex items-center gap-2">
                {value && <button type="button" onClick={() => { onChange(""); if (!withTime) setOpen(false); }} className="rounded-lg px-2.5 py-1.5 text-xs font-semibold text-zinc-500 transition hover:bg-zinc-100 hover:text-zinc-800">Hapus</button>}
                {withTime && <button type="button" onClick={() => { setOpen(false); triggerRef.current?.focus(); }} className="rounded-lg bg-gradient-to-r from-indigo-600 to-violet-600 px-3 py-1.5 text-xs font-bold text-white shadow-sm transition hover:from-indigo-700 hover:to-violet-700">Selesai</button>}
              </div>
            </div>
          </div>
        </div>,
        document.body,
      )}
    </>
  );
}
