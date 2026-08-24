"use client";

import { CalendarDays, Check, ChevronDown, ChevronLeft, ChevronRight, Info } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  canNavigateTimeRange,
  exclusiveEndDate,
  formatTimeRangeDateSpan,
  formatTimeRangePickerLabel,
  inclusiveEndDate,
  makeTimeRange,
  navigateTimeRange,
  type TimePreset,
  type TimeRange,
} from "@/lib/timeRange";
import { haptic } from "./haptics";
import { MobileSheet } from "./MobileSheet";

const rollingPresetKeys: { key: TimePreset; labelKey: string; metaKey: string }[] = [
  { key: "last7", labelKey: "timeRange.last7", metaKey: "timeRange.weekMeta" },
  { key: "last30", labelKey: "timeRange.last30", metaKey: "timeRange.monthMeta" },
  { key: "last90", labelKey: "timeRange.last90", metaKey: "timeRange.quarterMeta" },
  { key: "last12months", labelKey: "timeRange.last12months", metaKey: "timeRange.yearMeta" },
];

const calendarPresetKeys: { key: TimePreset; labelKey: string; metaKey: string }[] = [
  { key: "week", labelKey: "timeRange.currentWeek", metaKey: "timeRange.startsMonday" },
  { key: "month", labelKey: "timeRange.currentMonth", metaKey: "timeRange.naturalMonth" },
  { key: "quarter", labelKey: "timeRange.currentQuarter", metaKey: "timeRange.naturalQuarter" },
  { key: "year", labelKey: "timeRange.currentYear", metaKey: "timeRange.naturalYear" },
  { key: "all", labelKey: "timeRange.all", metaKey: "timeRange.fullLedger" },
];

type TimeRangePickerProps = {
  range: TimeRange;
  onChange: (range: TimeRange) => void;
};

export function TimeRangePicker({ range, onChange }: TimeRangePickerProps) {
  const { t } = useTranslation();
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [desktopOpen, setDesktopOpen] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);
  const [draftRange, setDraftRange] = useState(range);
  const [customStart, setCustomStart] = useState(range.start);
  const [customEnd, setCustomEnd] = useState(inclusiveEndDate(range));

  const canMovePrevious = canNavigateTimeRange(range, -1);
  const canMoveNext = canNavigateTimeRange(range, 1);
  const customValid = Boolean(customStart && customEnd && customStart <= customEnd);

  useEffect(() => {
    if (!desktopOpen) return;
    const handlePointerDown = (event: PointerEvent) => {
      if (!containerRef.current?.contains(event.target as Node)) setDesktopOpen(false);
    };
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setDesktopOpen(false);
    };
    document.addEventListener("pointerdown", handlePointerDown);
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      document.removeEventListener("pointerdown", handlePointerDown);
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [desktopOpen]);

  function syncDraft(nextRange: TimeRange) {
    setDraftRange(nextRange);
    setCustomStart(nextRange.start);
    setCustomEnd(inclusiveEndDate(nextRange));
  }

  function openPicker() {
    syncDraft(range);
    haptic(4);
    if (window.matchMedia("(min-width: 768px)").matches) {
      setDesktopOpen((open) => !open);
      setMobileOpen(false);
      return;
    }
    setDesktopOpen(false);
    setMobileOpen(true);
  }

  function selectPreset(preset: TimePreset) {
    haptic(4);
    syncDraft(makeTimeRange(preset));
  }

  function updateCustomStart(value: string) {
    setCustomStart(value);
    setDraftRange({ start: value, end: customEnd ? exclusiveEndDate(customEnd) : value, preset: "custom" });
  }

  function updateCustomEnd(value: string) {
    setCustomEnd(value);
    setDraftRange({ start: customStart, end: value ? exclusiveEndDate(value) : customStart, preset: "custom" });
  }

  function applyDraft() {
    if (draftRange.preset === "custom" && !customValid) return;
    const nextRange = draftRange.preset === "custom"
      ? { start: customStart, end: exclusiveEndDate(customEnd), preset: "custom" as const }
      : draftRange;
    haptic(7);
    onChange(nextRange);
    setDesktopOpen(false);
    setMobileOpen(false);
  }

  function move(delta: -1 | 1) {
    haptic(5);
    onChange(navigateTimeRange(range, delta));
  }

  const trigger = (
    <button
      type="button"
      className={`flex h-full min-w-0 flex-1 items-center gap-3 bg-panel px-4 text-left transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand md:min-w-64 md:flex-none md:gap-2.5 md:px-3 ${desktopOpen || mobileOpen ? "bg-tag shadow-[inset_0_0_0_1px_var(--brand)]" : "hover:bg-tag active:bg-tag"}`}
      onClick={openPicker}
      aria-haspopup="dialog"
      aria-expanded={desktopOpen || mobileOpen}
    >
      <span className="grid h-8 w-8 shrink-0 place-items-center rounded-md bg-tag text-brand md:h-7 md:w-7"><CalendarDays className="h-4 w-4" /></span>
      <span className="flex min-w-0 flex-1 flex-col justify-center gap-1 md:gap-0">
        <span className="block truncate text-sm font-semibold leading-5 tracking-[-0.012em] text-ink">{formatTimeRangePickerLabel(range)}</span>
        <span className="block truncate text-[11px] leading-4 tabular-nums text-stone">{formatTimeRangeDateSpan(range)}</span>
      </span>
      <ChevronDown className={`h-4 w-4 shrink-0 text-brand transition-transform ${desktopOpen ? "rotate-180" : ""}`} />
    </button>
  );

  const pickerBody = (
    <div className="grid min-w-0 gap-4 md:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)] md:gap-0">
      <div className="min-w-0 md:border-r md:border-line md:bg-paper md:p-5">
        <PresetSection label={t("timeRange.rollingRange")} presets={rollingPresetKeys} selected={draftRange.preset} onSelect={selectPreset} t={t} />
        <PresetSection className="mt-4" label={t("timeRange.naturalPeriod")} presets={calendarPresetKeys} selected={draftRange.preset} onSelect={selectPreset} t={t} />
      </div>
      <div className="min-w-0 md:p-6">
        <h3 className="text-lg font-semibold tracking-[-0.018em]">{t("timeRange.customDate")}</h3>
        <p className="mt-1 text-xs leading-5 text-stone">{t("timeRange.customDateHint")}</p>
        <label className="mt-4 block text-xs font-semibold text-stone" htmlFor="time-range-start">{t("timeRange.startDate")}</label>
        <input
          id="time-range-start"
          type="date"
          className="mt-1.5 h-11 w-full min-w-0 rounded-xl border border-line bg-panel px-3 text-sm tabular-nums text-ink outline-none focus:border-brand focus:ring-4 focus:ring-[var(--focus-ring)]"
          value={customStart}
          onChange={(event) => updateCustomStart(event.target.value)}
        />
        <label className="mt-3 block text-xs font-semibold text-stone" htmlFor="time-range-end">{t("timeRange.endDate")}</label>
        <input
          id="time-range-end"
          type="date"
          className="mt-1.5 h-11 w-full min-w-0 rounded-xl border border-line bg-panel px-3 text-sm tabular-nums text-ink outline-none focus:border-brand focus:ring-4 focus:ring-[var(--focus-ring)]"
          value={customEnd}
          onChange={(event) => updateCustomEnd(event.target.value)}
        />
        <div className="mt-4 flex items-start gap-2 rounded-xl bg-tag p-3 text-xs leading-5 text-olive">
          <Info className="mt-0.5 h-4 w-4 shrink-0 text-brand" />
          <span>{t("timeRange.rollingHint")}</span>
        </div>
      </div>
    </div>
  );

  return (
    <div ref={containerRef} className="relative w-full min-w-0 md:w-auto">
      <div data-time-range-control="segmented" className="flex h-14 w-full min-w-0 overflow-hidden rounded-lg border border-lineSoft bg-panel md:h-10">
        <button type="button" className="grid h-full w-10 shrink-0 place-items-center border-r border-line bg-panel text-brand transition-colors hover:bg-tag active:bg-tag focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand disabled:cursor-not-allowed disabled:opacity-40 md:w-9" onClick={() => move(-1)} disabled={!canMovePrevious} aria-label={t("timeRange.previousPeriod")}>
          <ChevronLeft className="h-4 w-4" />
        </button>
        {trigger}
        <button type="button" className="grid h-full w-10 shrink-0 place-items-center border-l border-line bg-panel text-brand transition-colors hover:bg-tag active:bg-tag focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand disabled:cursor-not-allowed disabled:opacity-40 md:w-9" onClick={() => move(1)} disabled={!canMoveNext} aria-label={t("timeRange.nextPeriod")}>
          <ChevronRight className="h-4 w-4" />
        </button>
      </div>

      {desktopOpen && (
        <div className="absolute right-0 top-[calc(100%+0.75rem)] z-50 hidden w-[min(46rem,calc(100vw-2rem))] overflow-hidden rounded-xl border border-lineSoft bg-panel shadow-[var(--float-shadow)] md:block" role="dialog" aria-label={t("timeRange.selectRange")}>
          <div className="flex items-center justify-between gap-3 border-b border-line px-5 py-4">
            <h2 className="text-lg font-semibold tracking-[-0.018em]">{t("timeRange.selectRange")}</h2>
            <span className="inline-flex items-center gap-1.5 rounded-full bg-tag px-2.5 py-1 text-[11px] font-semibold text-brand">
              <span className="h-1.5 w-1.5 rounded-full bg-brandLight" />{formatTimeRangePickerLabel(draftRange)}
            </span>
          </div>
          {pickerBody}
          <PickerFooter customValid={customValid || draftRange.preset !== "custom"} onCancel={() => setDesktopOpen(false)} onApply={applyDraft} t={t} />
        </div>
      )}

      <MobileSheet
        open={mobileOpen}
        title={t("timeRange.timeRange")}
        onClose={() => setMobileOpen(false)}
        size="md"
        bodyClassName="pb-5"
        panelClassName="md:hidden"
        footer={<div className="grid grid-cols-[minmax(0,0.75fr)_minmax(0,1.5fr)] gap-2"><button type="button" className="h-11 rounded-xl border border-line bg-panel text-sm font-semibold text-warm active:scale-95" onClick={() => syncDraft(range)}>{t("timeRange.reset")}</button><button type="button" className="h-11 rounded-xl bg-brand text-sm font-semibold text-paper active:scale-95 disabled:opacity-45" onClick={applyDraft} disabled={draftRange.preset === "custom" && !customValid}>{t("timeRange.applyWith", { label: formatTimeRangePickerLabel(draftRange) })}</button></div>}
      >
        <div className="mb-4 flex items-center gap-3 rounded-xl border border-brand/20 bg-tag p-3">
          <span className="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-panel text-brand"><CalendarDays className="h-4 w-4" /></span>
          <span className="min-w-0"><strong className="block truncate text-sm text-brand">{formatTimeRangePickerLabel(draftRange)}</strong><span className="mt-0.5 block truncate text-[11px] tabular-nums text-stone">{formatTimeRangeDateSpan(draftRange)}</span></span>
        </div>
        {pickerBody}
      </MobileSheet>
    </div>
  );
}

function PresetSection({ label, presets, selected, onSelect, t, className = "" }: { label: string; presets: { key: TimePreset; labelKey: string; metaKey: string }[]; selected: TimePreset; onSelect: (preset: TimePreset) => void; t: (key: string) => string; className?: string }) {
  return (
    <section className={className}>
      <div className="mb-2 px-1 text-[11px] font-bold uppercase tracking-[0.12em] text-stone">{label}</div>
      <div className="grid grid-cols-2 gap-2 md:grid-cols-1 md:gap-1">
        {presets.map((preset) => {
          const active = selected === preset.key;
          return (
            <button
              key={preset.key}
              type="button"
              className={`flex min-h-11 min-w-0 items-center justify-between gap-2 rounded-lg px-3.5 text-left text-sm transition-colors active:scale-[0.98] ${preset.key === "all" ? "col-span-2 md:col-span-1" : ""} ${active ? "bg-brand text-paper" : "border border-line bg-panel text-warm hover:bg-tag md:border-transparent md:bg-transparent"}`}
              onClick={() => onSelect(preset.key)}
              aria-pressed={active}
            >
              <span className="whitespace-nowrap">{t(preset.labelKey)}</span>
              {active ? <Check className="h-4 w-4 shrink-0" /> : <span className="hidden shrink-0 text-[10px] text-stone md:inline">{t(preset.metaKey)}</span>}
            </button>
          );
        })}
      </div>
    </section>
  );
}

function PickerFooter({ customValid, onCancel, onApply, t }: { customValid: boolean; onCancel: () => void; onApply: () => void; t: (key: string) => string }) {
  return (
    <div className="flex items-center justify-between gap-3 border-t border-line bg-paper/60 px-4 py-3">
      <span className="text-[11px] text-stone">{t("timeRange.applyHint")}</span>
      <div className="flex gap-2">
        <button type="button" className="h-9 rounded-xl border border-line bg-panel px-3 text-sm font-semibold text-warm hover:bg-tag active:scale-95" onClick={onCancel}>{t("timeRange.cancel")}</button>
        <button type="button" className="h-9 rounded-xl bg-brand px-4 text-sm font-semibold text-paper active:scale-95 disabled:opacity-45" onClick={onApply} disabled={!customValid}>{t("timeRange.applyRange")}</button>
      </div>
    </div>
  );
}
