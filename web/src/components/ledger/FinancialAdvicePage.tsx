"use client";

import { AlertTriangle, ArrowRight, CalendarDays, Clock, FileText, RefreshCw, Sparkles, WifiOff } from "lucide-react";
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { apiEndpointSettingsChangeEvent, apiFetch } from "@/lib/apiEndpoints";
import { readJson } from "@/lib/clientFetch";
import { formatMoney } from "@/lib/money";
import { localToday } from "@/lib/timeRange";
import i18n, { type SupportedLanguage } from "@/i18n";
import { ClientNavLink } from "./ClientNavLink";
import { useNetworkStatus } from "./hooks/useNetworkStatus";
import type { FinancialAdviceDisplayEvidence, FinancialAdviceMode, FinancialAdviceResponse } from "./types";

type AdviceState =
  | { phase: "idle" }
  | { phase: "loading" }
  | { phase: "updating"; previous: FinancialAdviceResponse }
  | { phase: "success"; response: FinancialAdviceResponse }
  | { phase: "offline" }
  | { phase: "error"; code: string; title: string; body: string; response?: FinancialAdviceResponse };

type AdvicePayloadResult =
  | { ok: true; response: FinancialAdviceResponse }
  | { ok: false; code: string; response?: FinancialAdviceResponse };

const adviceModes: FinancialAdviceMode[] = ["recent", "yearToDate"];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isOptionalString(value: unknown): boolean {
  return value == null || typeof value === "string";
}

function isOptionalNumber(value: unknown): boolean {
  return value == null || (typeof value === "number" && Number.isFinite(value));
}

function isAdviceNarrativePart(value: unknown): boolean {
  return isRecord(value)
    && typeof value.title === "string"
    && typeof value.body === "string"
    && Array.isArray(value.evidenceIds)
    && value.evidenceIds.every((id) => typeof id === "string");
}

function isAdviceSection(value: unknown): boolean {
  return isAdviceNarrativePart(value) && isRecord(value) && typeof value.topic === "string";
}

function isAdviceEvidence(value: unknown): boolean {
  if (!isRecord(value)) return false;
  return typeof value.id === "string"
    && ["income", "expense", "category", "cashflow", "savings", "assets", "anomaly", "coverage"].includes(String(value.kind))
    && typeof value.label === "string"
    && ["up", "down", "flat", "mixed"].includes(String(value.direction))
    && typeof value.currency === "string"
    && isOptionalString(value.detail)
    && isOptionalString(value.date)
    && isOptionalString(value.link)
    && [value.current, value.baseline, value.delta, value.ratio, value.baselineRatio, value.share, value.count, value.amount, value.median].every(isOptionalNumber);
}

export function isFinancialAdviceResponse(value: unknown): value is FinancialAdviceResponse {
  if (!isRecord(value) || !isRecord(value.metadata) || !isRecord(value.coverage) || !isRecord(value.ranges)) return false;
  const ranges = value.ranges;
  return isRecord(ranges.current)
    && typeof ranges.current.start === "string"
    && typeof ranges.current.end === "string"
    && isRecord(ranges.baseline)
    && typeof ranges.baseline.start === "string"
    && typeof ranges.baseline.end === "string"
    && Array.isArray(value.evidence)
    && value.evidence.every(isAdviceEvidence)
    && (value.opening == null || isAdviceNarrativePart(value.opening))
    && (value.observations == null || (Array.isArray(value.observations) && value.observations.every(isAdviceSection)))
    && (value.recommendations == null || (Array.isArray(value.recommendations) && value.recommendations.every(isAdviceSection)))
    && typeof value.metadata.asOf === "string"
    && typeof value.metadata.generatedAt === "string"
    && typeof value.metadata.ledgerRevision === "string"
    && typeof value.metadata.valuationCurrency === "string"
    && ["recent", "yearToDate"].includes(String(value.metadata.mode))
    && typeof value.metadata.locale === "string"
    && typeof value.metadata.modelGenerated === "boolean"
    && isOptionalString(value.metadata.provider)
    && isOptionalString(value.metadata.model)
    && ["full", "sparse", "empty"].includes(String(value.coverage.level))
    && typeof value.coverage.currentTxCount === "number"
    && typeof value.coverage.baselineTxCount === "number"
    && typeof value.coverage.activeExpenseDays === "number"
    && typeof value.coverage.unknownCategories === "number"
    && typeof value.coverage.missingValuation === "boolean"
    && (value.error == null || (isRecord(value.error) && typeof value.error.code === "string" && typeof value.error.message === "string"));
}

export function classifyFinancialAdvicePayload(status: number, payload: unknown): AdvicePayloadResult {
  if (isFinancialAdviceResponse(payload)) {
    if (status >= 200 && status < 300) return { ok: true, response: payload };
    return { ok: false, code: payload.error?.code ?? "provider_error", response: payload };
  }
  return { ok: false, code: status === 429 ? "rate_limited" : "request_failed" };
}

function adviceDirectionArrow(direction: FinancialAdviceDisplayEvidence["direction"]): string {
  switch (direction) {
    case "up":
      return "↑";
    case "down":
      return "↓";
    default:
      return "→";
  }
}

function percent(value: number): string {
  return `${(value * 100).toFixed(1)}%`;
}

function inclusiveEnd(endExclusive: string): string {
  if (!endExclusive) return endExclusive;
  const date = new Date(`${endExclusive}T00:00:00`);
  if (Number.isNaN(date.getTime())) return endExclusive;
  date.setDate(date.getDate() - 1);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function shortRevision(revision: string): string {
  return revision.length > 10 ? `${revision.slice(0, 10)}…` : revision;
}

function formatTime(value: string, locale: SupportedLanguage): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString(locale === "en-US" ? "en-US" : "zh-CN", { hour12: false, dateStyle: "medium", timeStyle: "short" });
}

export function adviceEvidenceLabel(evidence: FinancialAdviceDisplayEvidence, t: (key: string) => string): string {
  if (evidence.kind === "category") return evidence.label || t("advice.evidenceCategory");
  if (evidence.kind === "coverage") {
    if (evidence.current != null) return t("advice.evidenceActivity");
    if (evidence.count != null) return t("advice.evidenceUnknown");
    return t("advice.evidenceValuation");
  }
  switch (evidence.kind) {
    case "income":
      return t("advice.evidenceIncome");
    case "expense":
      return t("advice.evidenceExpense");
    case "cashflow":
      return t("advice.evidenceCashflow");
    case "savings":
      return t("advice.evidenceSavings");
    case "assets":
      return t("advice.evidenceAssets");
    case "anomaly":
      return evidence.label || t("advice.evidenceAnomaly");
    default:
      return evidence.label || t("advice.evidenceValuation");
  }
}

export function FinancialAdviceEvidenceRow({ evidence }: { evidence: FinancialAdviceDisplayEvidence }) {
  const { t } = useTranslation();
  const currency = evidence.currency || "CNY";
  const label = adviceEvidenceLabel(evidence, t);
  const arrow = adviceDirectionArrow(evidence.direction);
  const amount = (value: number | null | undefined) => (value == null ? null : formatMoney(value / 100, currency));

  return (
    <li className="grid gap-2 border-t border-line px-4 py-3 first:border-t-0 md:grid-cols-[minmax(0,1fr)_auto] md:items-baseline md:gap-6">
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <span className="truncate text-sm font-medium text-ink">{label}</span>
          <span aria-hidden="true" className="text-xs tabular-nums text-stone">{arrow}</span>
        </div>
        {evidence.kind === "coverage" && evidence.current == null && evidence.count == null && (
          <p className="mt-0.5 text-sm text-stone">{t("advice.evidenceValuationDetail")}</p>
        )}
        {evidence.kind === "coverage" && evidence.current != null && (
          <p className="mt-0.5 text-sm text-stone">
            {t("advice.evidenceCount", { count: evidence.count ?? 0 })} · {t("advice.evidenceActiveDays", { count: evidence.current })}
          </p>
        )}
        {evidence.kind === "coverage" && evidence.current == null && evidence.count != null && (
          <p className="mt-0.5 text-sm text-stone">{t("advice.evidenceUnknownCount", { count: evidence.count })}</p>
        )}
        {evidence.kind === "anomaly" && (
          <p className="mt-0.5 text-sm text-stone">
            {amount(evidence.amount)} · {t("advice.evidenceAnomalyDate", { date: evidence.date ?? "" })} · {t("advice.evidenceAnomalyBasis", { median: amount(evidence.median) })}
          </p>
        )}
        {evidence.kind !== "coverage" && evidence.kind !== "anomaly" && evidence.current != null && (
          <div className="mt-1 flex flex-wrap items-baseline gap-x-3 gap-y-0.5">
            <span className="text-lg font-semibold tabular-nums text-ink">{amount(evidence.current)}</span>
            {evidence.baseline != null && <span className="text-sm text-stone">{t("advice.evidenceBaseline", { value: amount(evidence.baseline) })}</span>}
            {evidence.delta != null && <span className="text-sm tabular-nums text-stone">{t("advice.evidenceDelta", { value: amount(evidence.delta) })}</span>}
            {evidence.ratio != null && <span className="text-sm tabular-nums text-stone">{t("advice.evidenceChangeRatio", { value: percent(evidence.ratio) })}</span>}
            {evidence.share != null && <span className="text-sm tabular-nums text-stone">{t("advice.evidenceShare", { value: percent(evidence.share) })}</span>}
            {evidence.count != null && <span className="text-sm tabular-nums text-stone">{t("advice.evidenceCount", { count: evidence.count })}</span>}
          </div>
        )}
        {evidence.kind === "savings" && (
          <div className="mt-1 flex flex-wrap items-baseline gap-x-3 gap-y-0.5">
            <span className="text-lg font-semibold tabular-nums text-ink">{evidence.ratio == null ? "—" : percent(evidence.ratio)}</span>
            <span className="text-sm text-stone">{t("advice.evidenceBaseline", { value: evidence.baselineRatio == null ? "—" : percent(evidence.baselineRatio) })}</span>
          </div>
        )}
      </div>
      {evidence.link && (
        <ClientNavLink href={evidence.link} className="inline-flex shrink-0 items-center gap-1 rounded-md px-1 py-2 text-sm font-medium text-brand focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand">
          {t("advice.viewTransactions")}
          <ArrowRight className="h-3.5 w-3.5" aria-hidden="true" />
        </ClientNavLink>
      )}
    </li>
  );
}

export function FinancialAdviceLetter({ response }: { response: FinancialAdviceResponse }) {
  const { t } = useTranslation();
  const byID = new Map<string, FinancialAdviceDisplayEvidence>();
  for (const item of response.evidence) byID.set(item.id, item);
  const cited = (ids: string[] | undefined) =>
    (ids ?? []).map((id) => byID.get(id)).filter((item): item is FinancialAdviceDisplayEvidence => item != null);

  return (
    <div className="app-page-transition grid gap-10">
      {response.coverage.level === "sparse" && (
        <aside className="rounded-2xl border border-line bg-panel px-4 py-3 text-sm text-stone">
          <span className="font-medium text-ink">{t("advice.sparseNoteTitle")}</span> {t("advice.sparseNote")}
        </aside>
      )}
      <article className="max-w-[65ch]">
        {response.opening && (
          <section aria-labelledby="advice-opening-heading">
            <h2 id="advice-opening-heading" className="font-serif text-2xl font-medium leading-snug text-ink md:text-3xl">{response.opening.title}</h2>
            <p className="mt-4 text-base leading-7 text-ink/90">{response.opening.body}</p>
            {cited(response.opening.evidenceIds).length > 0 && (
              <ul className="mt-5 overflow-hidden rounded-2xl border border-line bg-panel">
                {cited(response.opening.evidenceIds).map((item) => <FinancialAdviceEvidenceRow key={item.id} evidence={item} />)}
              </ul>
            )}
          </section>
        )}
        {(response.observations ?? []).length > 0 && (
          <section className="mt-10" aria-labelledby="advice-observations-heading">
            <h2 id="advice-observations-heading" className="font-serif text-xl font-medium text-ink">{t("advice.observationsTitle")}</h2>
            <ol className="mt-4 grid gap-8">
              {(response.observations ?? []).map((observation, index) => (
                <li key={`${observation.topic}:${index}`}>
                  <div className="grid gap-1">
                    <span className="text-xs font-medium uppercase tracking-wide text-stone">{index + 1}</span>
                    <h3 className="text-base font-semibold text-ink">{observation.title}</h3>
                    <p className="text-sm leading-6 text-ink/85">{observation.body}</p>
                  </div>
                  {cited(observation.evidenceIds).length > 0 && (
                    <ul className="mt-3 overflow-hidden rounded-2xl border border-line bg-panel">
                      {cited(observation.evidenceIds).map((item) => <FinancialAdviceEvidenceRow key={item.id} evidence={item} />)}
                    </ul>
                  )}
                </li>
              ))}
            </ol>
          </section>
        )}
        {(response.recommendations ?? []).length > 0 && (
          <section className="mt-10" aria-labelledby="advice-recommendations-heading">
            <h2 id="advice-recommendations-heading" className="font-serif text-xl font-medium text-ink">{t("advice.recommendationsTitle")}</h2>
            <ol className="mt-4 grid gap-4">
              {(response.recommendations ?? []).map((recommendation, index) => (
                <li key={`${recommendation.topic}:${index}`} className="flex gap-3 rounded-2xl border border-line bg-panel px-4 py-3">
                  <span className="grid h-6 w-6 shrink-0 place-items-center rounded-full bg-brand text-xs font-semibold text-paper">{index + 1}</span>
                  <div className="min-w-0">
                    <h3 className="text-sm font-semibold text-ink">{recommendation.title}</h3>
                    <p className="mt-0.5 text-sm leading-6 text-ink/85">{recommendation.body}</p>
                    {cited(recommendation.evidenceIds).length > 0 && (
                      <ul className="mt-3 overflow-hidden rounded-2xl border border-line bg-paper">
                        {cited(recommendation.evidenceIds).map((item) => <FinancialAdviceEvidenceRow key={item.id} evidence={item} />)}
                      </ul>
                    )}
                  </div>
                </li>
              ))}
            </ol>
          </section>
        )}
      </article>
    </div>
  );
}

export function FinancialAdvicePanel({ icon, title, body, children, tone = "default" }: { icon: ReactNode; title: string; body: string; children?: ReactNode; tone?: "default" | "warning" }) {
  return (
    <section className={`rounded-2xl border px-5 py-8 md:px-8 ${tone === "warning" ? "border-[var(--danger)]/40 bg-[var(--danger)]/5" : "border-line bg-panel"}`}>
      <div className="grid place-items-start gap-3">
        <span className="grid h-10 w-10 place-items-center rounded-full bg-tag text-brand">{icon}</span>
        <div className="max-w-[65ch]">
          <h2 className="font-serif text-xl font-medium text-ink">{title}</h2>
          <p className="mt-2 text-sm leading-6 text-stone">{body}</p>
        </div>
        {children && <div className="mt-2 flex flex-wrap items-center gap-3">{children}</div>}
      </div>
    </section>
  );
}

export function FinancialAdviceEmptyPanel() {
  const { t } = useTranslation();
  return (
    <FinancialAdvicePanel icon={<CalendarDays className="h-5 w-5" aria-hidden="true" />} title={t("advice.emptyTitle")} body={t("advice.emptyBody")}>
      <ClientNavLink href="/transactions" className="inline-flex h-11 items-center gap-2 rounded-xl border border-line bg-paper px-4 text-sm font-medium text-ink transition hover:bg-tag focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand">
        {t("advice.openTransactions")}
      </ClientNavLink>
      <ClientNavLink href="/imports" className="inline-flex h-11 items-center gap-2 rounded-xl border border-line bg-paper px-4 text-sm font-medium text-ink transition hover:bg-tag focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand">
        {t("advice.openImports")}
      </ClientNavLink>
    </FinancialAdvicePanel>
  );
}

export function FinancialAdviceErrorPanel({ title, body, evidence, onRetry }: { title: string; body: string; evidence: FinancialAdviceDisplayEvidence[]; onRetry: () => void }) {
  const { t } = useTranslation();
  return (
    <div className="grid gap-4">
      <FinancialAdvicePanel tone="warning" icon={<AlertTriangle className="h-5 w-5" aria-hidden="true" />} title={title} body={body}>
        <button
          type="button"
          className="inline-flex h-11 items-center justify-center gap-2 rounded-xl bg-brand px-4 text-sm font-semibold text-paper transition active:scale-[0.98] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand"
          onClick={onRetry}
        >
          <RefreshCw className="h-4 w-4" aria-hidden="true" />
          {t("advice.regenerate")}
        </button>
      </FinancialAdvicePanel>
      {evidence.length > 0 && (
        <>
          <p className="text-xs text-stone">{t("advice.evidenceOnlyNote")}</p>
          <ul className="overflow-hidden rounded-2xl border border-line bg-panel">
            {evidence.map((item) => <FinancialAdviceEvidenceRow key={item.id} evidence={item} />)}
          </ul>
        </>
      )}
    </div>
  );
}

function AdviceSkeleton() {
  return (
    <div className="grid gap-4" aria-hidden="true">
      <div className="h-8 w-2/3 rounded-lg bg-tag motion-safe:animate-pulse" />
      <div className="h-4 w-full rounded-lg bg-tag motion-safe:animate-pulse" />
      <div className="h-4 w-5/6 rounded-lg bg-tag motion-safe:animate-pulse" />
      <div className="mt-4 h-40 rounded-2xl border border-line bg-panel" />
      <div className="h-32 rounded-2xl border border-line bg-panel" />
    </div>
  );
}

export function FinancialAdvicePage({ valuationCurrency, onSensitiveLocked }: { valuationCurrency: string; onSensitiveLocked: () => void }) {
  const { t } = useTranslation();
  const online = useNetworkStatus();
  const [mode, setMode] = useState<FinancialAdviceMode>("recent");
  const [state, setState] = useState<AdviceState>({ phase: "idle" });
  const abortRef = useRef<AbortController | null>(null);
  const sequenceRef = useRef(0);
  const resultRef = useRef<HTMLDivElement | null>(null);
  const locale: SupportedLanguage = i18n.language === "en-US" ? "en-US" : "zh-CN";

  const clear = useCallback(() => {
    abortRef.current?.abort();
    abortRef.current = null;
    sequenceRef.current += 1;
    setState({ phase: "idle" });
  }, []);

  useEffect(() => {
    clear();
  }, [mode, locale, valuationCurrency, clear]);

  useEffect(() => {
    const onEndpointChange = () => clear();
    window.addEventListener(apiEndpointSettingsChangeEvent, onEndpointChange);
    return () => {
      window.removeEventListener(apiEndpointSettingsChangeEvent, onEndpointChange);
      abortRef.current?.abort();
      sequenceRef.current += 1;
    };
  }, [clear]);

  const generate = useCallback(async (nextMode: FinancialAdviceMode, isRegenerate: boolean) => {
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    const sequence = ++sequenceRef.current;
    if (!online) {
      setState({ phase: "offline" });
      return;
    }
    setState((current) => (isRegenerate && current.phase === "success" ? { phase: "updating", previous: current.response } : { phase: "loading" }));
    try {
      const response = await apiFetch("/api/ai/financial-advice", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        cache: "no-store",
        body: JSON.stringify({ mode: nextMode, asOf: localToday(), valuationCurrency, locale }),
        signal: controller.signal,
      }, { kind: "read" });
      if (response.status === 401 || response.status === 423) {
        onSensitiveLocked();
        return;
      }
      const payload = await readJson<unknown>(response);
      if (sequenceRef.current !== sequence) return;
      const result = classifyFinancialAdvicePayload(response.status, payload);
      if (!result.ok) {
        const message = result.response?.error?.message ?? adviceErrorBody(result.code, t);
        setState({ phase: "error", code: result.code, title: adviceErrorTitle(result.code, t), body: message, response: result.response });
        return;
      }
      setState({ phase: "success", response: result.response });
    } catch {
      if (sequenceRef.current !== sequence || controller.signal.aborted) return;
      if (!window.navigator.onLine) {
        setState({ phase: "offline" });
      } else {
        setState({ phase: "error", code: "request_failed", title: t("advice.errorRequestFailedTitle"), body: t("advice.errorRequestFailedBody") });
      }
    } finally {
      if (abortRef.current === controller) abortRef.current = null;
    }
  }, [locale, online, onSensitiveLocked, t, valuationCurrency]);

  useEffect(() => {
    if (state.phase === "success" && state.response.opening) {
      resultRef.current?.focus();
    }
  }, [state]);

  const busy = state.phase === "loading" || state.phase === "updating";
  const displayedResponse = state.phase === "success" ? state.response : state.phase === "updating" ? state.previous : state.phase === "error" ? state.response : undefined;
  const hasGeneratedResult = displayedResponse != null;
  const liveStatus = state.phase === "loading"
    ? t("advice.liveStatusGenerating")
    : state.phase === "updating"
      ? t("advice.liveStatusUpdating")
      : state.phase === "success"
        ? t("advice.liveStatusReady")
        : state.phase === "error"
          ? t("advice.liveStatusError")
          : state.phase === "offline"
            ? t("advice.liveStatusOffline")
            : t("advice.liveStatusIdle");

  return (
    <section className="mx-auto w-full max-w-6xl px-4 pb-20 pt-6 md:px-6" aria-busy={busy} aria-labelledby="financial-advice-title" data-advice-page>
      <header className="grid gap-4">
        <div className="inline-flex w-fit items-center gap-2 rounded-full border border-line bg-paper px-3 py-1 text-xs uppercase tracking-wide text-stone">
          <Sparkles className="h-3.5 w-3.5 text-brand" aria-hidden="true" />
          {t("ledgerApp.pageAdvice")}
        </div>
        <div className="grid gap-3 md:grid-cols-[minmax(0,1fr)_auto] md:items-end">
          <div className="max-w-[65ch]">
            <h1 id="financial-advice-title" className="font-serif text-3xl font-medium leading-tight text-ink">{t("advice.title")}</h1>
            <p className="mt-2 text-sm leading-6 text-stone">{t("advice.description")}</p>
          </div>
          <div className="flex flex-wrap items-center gap-3">
            <div role="group" aria-label={t("advice.modeLabel")} className="inline-flex rounded-xl border border-line bg-paper p-1">
              {adviceModes.map((item) => (
                <button
                  key={item}
                  type="button"
                  className={`rounded-lg px-3 py-2 text-sm font-medium transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand ${mode === item ? "bg-brand text-paper" : "text-stone hover:bg-tag"}`}
                  aria-pressed={mode === item}
                  onClick={() => setMode(item)}
                >
                  {item === "recent" ? t("advice.recent90Days") : t("advice.yearToDate")}
                </button>
              ))}
            </div>
            <button
              type="button"
              className="inline-flex h-11 items-center justify-center gap-2 rounded-xl bg-brand px-4 text-sm font-semibold text-paper transition active:scale-[0.98] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand disabled:cursor-not-allowed disabled:opacity-60"
              disabled={busy}
              onClick={() => void generate(mode, hasGeneratedResult)}
            >
              <RefreshCw className={`h-4 w-4 ${busy ? "motion-safe:animate-spin" : ""}`} aria-hidden="true" />
              {hasGeneratedResult ? t("advice.regenerate") : state.phase === "updating" ? t("advice.updating") : state.phase === "loading" ? t("advice.generating") : t("advice.generate")}
            </button>
          </div>
        </div>
        <p className="min-h-5 text-xs text-stone" role="status" aria-live="polite">{liveStatus}</p>
        {displayedResponse && (
          <dl className="flex flex-wrap gap-x-5 gap-y-1 border-t border-line pt-3 text-xs text-stone">
            <div className="flex items-center gap-1.5"><CalendarDays className="h-3.5 w-3.5" aria-hidden="true" /><dt className="sr-only">{t("advice.period")}</dt><dd>{t("advice.period", { start: displayedResponse.ranges.current.start, end: inclusiveEnd(displayedResponse.ranges.current.end) })}</dd></div>
            <div className="flex items-center gap-1.5"><dt className="sr-only">{t("advice.asOf")}</dt><dd>{t("advice.asOf", { date: displayedResponse.metadata.asOf })}</dd></div>
            <div className="flex items-center gap-1.5"><Clock className="h-3.5 w-3.5" aria-hidden="true" /><dt className="sr-only">{t("advice.generatedAt")}</dt><dd>{t("advice.generatedAt", { time: formatTime(displayedResponse.metadata.generatedAt, locale) })}</dd></div>
            <div><dt className="sr-only">{t("advice.ledgerRevision")}</dt><dd>{t("advice.ledgerRevision", { revision: shortRevision(displayedResponse.metadata.ledgerRevision) })}</dd></div>
            <div><dt className="sr-only">{t("advice.currency")}</dt><dd>{t("advice.currency", { currency: displayedResponse.metadata.valuationCurrency })}</dd></div>
            {displayedResponse.metadata.modelGenerated && <div><dt className="sr-only">{t("advice.modelGenerated")}</dt><dd>{displayedResponse.metadata.provider ? t("advice.modelGenerated", { provider: displayedResponse.metadata.provider }) : t("advice.modelGeneratedGeneric")}{displayedResponse.metadata.model ? ` · ${t("advice.modelName", { model: displayedResponse.metadata.model })}` : ""}</dd></div>}
          </dl>
        )}
      </header>

      <div className="mt-8 grid gap-8">
        <p className="max-w-[65ch] rounded-2xl border border-line bg-panel px-4 py-3 text-xs leading-5 text-stone">
          <FileText className="mr-1.5 inline h-3.5 w-3.5 align-[-2px] text-brand" aria-hidden="true" />
          {t("advice.disclosure")}
        </p>

        {state.phase === "idle" && (
          <FinancialAdvicePanel icon={<Sparkles className="h-5 w-5" aria-hidden="true" />} title={t("advice.initialTitle")} body={t("advice.initialBody")}>
            <p className="w-full text-xs text-stone">{t("advice.initialTopics")}</p>
            <button
              type="button"
              className="mt-2 inline-flex h-11 items-center justify-center gap-2 rounded-xl bg-brand px-4 text-sm font-semibold text-paper transition active:scale-[0.98] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand"
              onClick={() => void generate(mode, false)}
            >
              {t("advice.generate")}
            </button>
          </FinancialAdvicePanel>
        )}

        {state.phase === "loading" && <AdviceSkeleton />}

        {state.phase === "offline" && (
          <FinancialAdvicePanel tone="warning" icon={<WifiOff className="h-5 w-5" aria-hidden="true" />} title={t("advice.errorOfflineTitle")} body={t("advice.errorOfflineBody")}>
            <button
              type="button"
              className="inline-flex h-11 items-center justify-center gap-2 rounded-xl bg-brand px-4 text-sm font-semibold text-paper transition active:scale-[0.98] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand"
              onClick={() => void generate(mode, false)}
            >
              {t("advice.generate")}
            </button>
          </FinancialAdvicePanel>
        )}

        {(state.phase === "updating") && <FinancialAdviceLetter response={state.previous} />}

        {state.phase === "success" && state.response.coverage.level === "empty" && <FinancialAdviceEmptyPanel />}

        {state.phase === "success" && state.response.coverage.level !== "empty" && (
          <div ref={resultRef} tabIndex={-1} className="outline-none">
            {!state.response.metadata.modelGenerated && state.response.error && (
              <div className="mb-6">
                <FinancialAdviceErrorPanel title={t(`advice.${state.response.error.code === "provider_not_configured" ? "errorProviderNotConfiguredTitle" : state.response.error.code === "provider_timeout" ? "errorProviderTimeoutTitle" : state.response.error.code === "model_output_invalid" ? "errorModelOutputInvalidTitle" : "errorProviderErrorTitle"}`)} body={state.response.error.message} evidence={state.response.evidence} onRetry={() => void generate(mode, true)} />
              </div>
            )}
            <FinancialAdviceLetter response={state.response} />
          </div>
        )}

        {state.phase === "error" && state.code !== "offline" && (
          <FinancialAdviceErrorPanel title={state.title} body={state.body} evidence={state.response?.evidence ?? []} onRetry={() => void generate(mode, true)} />
        )}
      </div>
    </section>
  );
}

function adviceErrorTitle(code: string, t: (key: string) => string): string {
  switch (code) {
    case "provider_not_configured":
      return t("advice.errorProviderNotConfiguredTitle");
    case "provider_timeout":
      return t("advice.errorProviderTimeoutTitle");
    case "model_output_invalid":
      return t("advice.errorModelOutputInvalidTitle");
    case "offline":
      return t("advice.errorOfflineTitle");
    case "rate_limited":
      return t("advice.errorRateLimitedTitle");
    case "request_failed":
      return t("advice.errorRequestFailedTitle");
    default:
      return t("advice.errorProviderErrorTitle");
  }
}

function adviceErrorBody(code: string, t: (key: string) => string): string {
  return code === "rate_limited" ? t("advice.errorRateLimitedBody") : t("advice.errorRequestFailedBody");
}
