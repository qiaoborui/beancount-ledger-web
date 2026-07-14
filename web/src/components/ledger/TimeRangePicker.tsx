"use client";

import { CalendarDays, Check, ChevronDown, ChevronLeft, ChevronRight, Info } from "lucide-react";
import { useEffect, useRef, useState } from "react";
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

const rollingPresets: { key: TimePreset; label: string; meta: string }[] = [
  { key: "last7", label: "过去 7 天", meta: "7d" },
  { key: "last30", label: "过去 30 天", meta: "30d" },
  { key: "last90", label: "过去 90 天", meta: "90d" },
  { key: "last12months", label: "过去 12 个月", meta: "12mo" },
];

const calendarPresets: { key: TimePreset; label: string; meta: string }[] = [
  { key: "week", label: "当前周", meta: "周一开始" },
  { key: "month", label: "当前月", meta: "自然月" },
  { key: "quarter", label: "当前季度", meta: "自然季度" },
  { key: "year", label: "当前年", meta: "自然年" },
  { key: "all", label: "全部时间", meta: "完整账本" },
];

type TimeRangePickerProps = {
  range: TimeRange;
  onChange: (range: TimeRange) => void;
};

export function TimeRangePicker({ range, onChange }: TimeRangePickerProps) {
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
      className={`flex h-12 min-w-0 flex-1 items-center gap-2.5 rounded-xl border bg-panel px-2.5 text-left transition-colors active:scale-[0.98] md:min-w-60 md:flex-none ${desktopOpen || mobileOpen ? "border-brand shadow-[0_0_0_3px_var(--focus-ring)]" : "border-line hover:bg-tag"}`}
      onClick={openPicker}
      aria-haspopup="dialog"
      aria-expanded={desktopOpen || mobileOpen}
    >
      <span className="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-tag text-brand"><CalendarDays className="h-4 w-4" /></span>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-sm font-semibold text-ink">{formatTimeRangePickerLabel(range)}</span>
        <span className="mt-0.5 block truncate text-[11px] tabular-nums text-stone">{formatTimeRangeDateSpan(range)}</span>
      </span>
      <ChevronDown className={`h-4 w-4 shrink-0 text-brand transition-transform ${desktopOpen ? "rotate-180" : ""}`} />
    </button>
  );

  const pickerBody = (
    <div className="grid min-w-0 gap-4 md:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)] md:gap-0">
      <div className="min-w-0 md:border-r md:border-line md:bg-paper md:p-4">
        <PresetSection label="滚动范围" presets={rollingPresets} selected={draftRange.preset} onSelect={selectPreset} />
        <PresetSection className="mt-4" label="自然周期" presets={calendarPresets} selected={draftRange.preset} onSelect={selectPreset} />
      </div>
      <div className="min-w-0 md:p-5">
        <h3 className="font-serif text-lg font-semibold">自定义日期</h3>
        <p className="mt-1 text-xs leading-5 text-stone">选择固定起止日期，结束日期会包含当天。</p>
        <label className="mt-4 block text-xs font-semibold text-stone" htmlFor="time-range-start">开始日期</label>
        <input
          id="time-range-start"
          type="date"
          className="mt-1.5 h-11 w-full min-w-0 rounded-xl border border-line bg-panel px-3 text-sm tabular-nums text-ink outline-none focus:border-brand focus:ring-4 focus:ring-[var(--focus-ring)]"
          value={customStart}
          onChange={(event) => updateCustomStart(event.target.value)}
        />
        <label className="mt-3 block text-xs font-semibold text-stone" htmlFor="time-range-end">结束日期</label>
        <input
          id="time-range-end"
          type="date"
          className="mt-1.5 h-11 w-full min-w-0 rounded-xl border border-line bg-panel px-3 text-sm tabular-nums text-ink outline-none focus:border-brand focus:ring-4 focus:ring-[var(--focus-ring)]"
          value={customEnd}
          onChange={(event) => updateCustomEnd(event.target.value)}
        />
        <div className="mt-4 flex items-start gap-2 rounded-xl bg-tag p-3 text-xs leading-5 text-olive">
          <Info className="mt-0.5 h-4 w-4 shrink-0 text-brand" />
          <span>“过去 30 天”会随今天滚动，“当前月”始终按自然月边界统计。</span>
        </div>
      </div>
    </div>
  );

  return (
    <div ref={containerRef} className="relative flex w-full min-w-0 items-center gap-1.5 md:w-auto">
      <button type="button" className="grid h-12 w-10 shrink-0 place-items-center rounded-xl border border-line bg-panel text-brand transition-colors hover:bg-tag active:scale-95 disabled:cursor-not-allowed disabled:opacity-40" onClick={() => move(-1)} disabled={!canMovePrevious} aria-label="上一时间段">
        <ChevronLeft className="h-4 w-4" />
      </button>
      {trigger}
      <button type="button" className="grid h-12 w-10 shrink-0 place-items-center rounded-xl border border-line bg-panel text-brand transition-colors hover:bg-tag active:scale-95 disabled:cursor-not-allowed disabled:opacity-40" onClick={() => move(1)} disabled={!canMoveNext} aria-label="下一时间段">
        <ChevronRight className="h-4 w-4" />
      </button>

      {desktopOpen && (
        <div className="absolute right-0 top-[calc(100%+0.625rem)] z-50 hidden w-[min(42rem,calc(100vw-2rem))] overflow-hidden rounded-2xl border border-lineSoft bg-panel shadow-[var(--float-shadow)] md:block" role="dialog" aria-label="选择时间范围">
          <div className="flex items-center justify-between gap-3 border-b border-line px-4 py-3">
            <h2 className="font-serif text-lg font-semibold">选择时间范围</h2>
            <span className="inline-flex items-center gap-1.5 rounded-full bg-tag px-2.5 py-1 text-[11px] font-semibold text-brand">
              <span className="h-1.5 w-1.5 rounded-full bg-brandLight" />{formatTimeRangePickerLabel(draftRange)}
            </span>
          </div>
          {pickerBody}
          <PickerFooter customValid={customValid || draftRange.preset !== "custom"} onCancel={() => setDesktopOpen(false)} onApply={applyDraft} />
        </div>
      )}

      <MobileSheet
        open={mobileOpen}
        title="时间范围"
        onClose={() => setMobileOpen(false)}
        size="md"
        bodyClassName="pb-5"
        panelClassName="md:hidden"
        footer={<div className="grid grid-cols-[minmax(0,0.75fr)_minmax(0,1.5fr)] gap-2"><button type="button" className="h-11 rounded-xl border border-line bg-panel text-sm font-semibold text-warm active:scale-95" onClick={() => syncDraft(range)}>重置</button><button type="button" className="h-11 rounded-xl bg-brand text-sm font-semibold text-paper active:scale-95 disabled:opacity-45" onClick={applyDraft} disabled={draftRange.preset === "custom" && !customValid}>应用：{formatTimeRangePickerLabel(draftRange)}</button></div>}
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

function PresetSection({ label, presets, selected, onSelect, className = "" }: { label: string; presets: { key: TimePreset; label: string; meta: string }[]; selected: TimePreset; onSelect: (preset: TimePreset) => void; className?: string }) {
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
              className={`flex min-h-10 min-w-0 items-center justify-between gap-2 rounded-xl px-3 text-left text-sm transition-colors active:scale-[0.98] ${preset.key === "all" ? "col-span-2 md:col-span-1" : ""} ${active ? "bg-brand text-paper" : "border border-line bg-panel text-warm hover:bg-tag md:border-transparent md:bg-transparent"}`}
              onClick={() => onSelect(preset.key)}
              aria-pressed={active}
            >
              <span className="truncate">{preset.label}</span>
              {active ? <Check className="h-4 w-4 shrink-0" /> : <span className="hidden shrink-0 text-[10px] text-stone md:inline">{preset.meta}</span>}
            </button>
          );
        })}
      </div>
    </section>
  );
}

function PickerFooter({ customValid, onCancel, onApply }: { customValid: boolean; onCancel: () => void; onApply: () => void }) {
  return (
    <div className="flex items-center justify-between gap-3 border-t border-line bg-paper/60 px-4 py-3">
      <span className="text-[11px] text-stone">快捷范围选择后点击应用</span>
      <div className="flex gap-2">
        <button type="button" className="h-9 rounded-xl border border-line bg-panel px-3 text-sm font-semibold text-warm hover:bg-tag active:scale-95" onClick={onCancel}>取消</button>
        <button type="button" className="h-9 rounded-xl bg-brand px-4 text-sm font-semibold text-paper active:scale-95 disabled:opacity-45" onClick={onApply} disabled={!customValid}>应用范围</button>
      </div>
    </div>
  );
}
