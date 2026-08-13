import { useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { ArrowRight, Bot, ChevronDown, CircleAlert, CircleDollarSign, LoaderCircle, RefreshCw, Send } from "lucide-react";
import { apiFetch } from "@/lib/apiEndpoints";
import { readLedgerAgentStream } from "@/lib/ledgerAgentStream";
import i18n from "@/i18n";
import { AgentMessageBubble } from "./AgentMessageBubble";

type FundingKind = "cash" | "bank_card" | "digital_wallet" | "savings" | "investment";
type LiabilityKind = "credit_card" | "consumer_loan" | "other_debt";
type FundingSpace = { kind: FundingKind; name: string; account: string; openingBalance: string; currency: string };
type Liability = { kind: LiabilityKind; name: string; account: string; openingBalance: string; currency: string };
type CategorySelection = { templateKey?: string; customName?: string; account: string };
type ChatMessage = { role: "user" | "assistant"; content: string };

export type OnboardingPayload = {
  title: string;
  currency: string;
  startDate: string;
  fundingSpaces: FundingSpace[];
  liabilities: Liability[];
  incomeCategories: CategorySelection[];
  expenseCategories: CategorySelection[];
};

export function OnboardingStatusUnavailable({ error, onRetry }: { error: string; onRetry: () => void }) {
  const { t } = useTranslation();
  return <main className="grid min-h-dvh place-items-center bg-paper px-5 py-10 text-ink">
    <section className="w-full max-w-2xl border-y border-line bg-panel px-5 py-8 sm:px-8" aria-labelledby="onboarding-status-title">
      <span className="grid h-10 w-10 place-items-center rounded-md bg-danger/10 text-danger"><CircleAlert className="h-5 w-5" /></span>
      <h1 id="onboarding-status-title" className="mt-5 text-2xl font-semibold tracking-[-0.02em]">{t("onboarding.statusUnavailableTitle")}</h1>
      <p className="mt-3 text-sm leading-6 text-olive">{t("onboarding.statusUnavailableDesc")}</p>
      <p role="alert" className="mt-4 break-words rounded-md bg-danger/10 px-4 py-3 font-mono text-xs leading-5 text-danger">{error}</p>
      <div className="mt-6 flex flex-wrap gap-3">
        <button type="button" onClick={onRetry} className="inline-flex h-11 min-w-40 items-center justify-center gap-2 rounded-md bg-brand px-4 text-sm font-medium text-paper transition-transform active:scale-[0.98]"><RefreshCw className="h-4 w-4" />{t("onboarding.retryStatus")}</button>
        <a href="/api/setup/status" target="_blank" rel="noreferrer" className="inline-flex h-11 min-w-40 items-center justify-center rounded-md border border-line bg-paper px-4 text-sm font-medium text-brand hover:bg-tag">{t("onboarding.openReadiness")}</a>
      </div>
    </section>
  </main>;
}

function normalizeOnboardingDraft(draft: OnboardingPayload): OnboardingPayload {
  return {
    ...draft,
    fundingSpaces: draft.fundingSpaces ?? [],
    liabilities: draft.liabilities ?? [],
    incomeCategories: draft.incomeCategories ?? [],
    expenseCategories: draft.expenseCategories ?? [],
  };
}

const fundingLabelKeys: Record<FundingKind, string> = {
  cash: "onboarding.fundingCash",
  digital_wallet: "onboarding.fundingDigitalWallet",
  bank_card: "onboarding.fundingBankCard",
  savings: "onboarding.fundingSavings",
  investment: "onboarding.fundingInvestment",
};

const liabilityLabelKeys: Record<LiabilityKind, string> = {
  credit_card: "onboarding.liabilityCreditCard",
  consumer_loan: "onboarding.liabilityConsumerLoan",
  other_debt: "onboarding.liabilityOtherDebt",
};

const incomeLabelKeys: Record<string, string> = {
  salary: "onboarding.incomeSalary", bonus: "onboarding.incomeBonus", freelance: "onboarding.incomeFreelance", interest: "onboarding.incomeInterest", investment: "onboarding.incomeInvestment", other_income: "onboarding.incomeOther",
};

const expenseLabelKeys: Record<string, string> = {
  groceries: "onboarding.expenseGroceries", dining: "onboarding.expenseDining", coffee: "onboarding.expenseCoffee", public_transport: "onboarding.expensePublicTransport", taxi: "onboarding.expenseTaxi", rent: "onboarding.expenseRent", utilities: "onboarding.expenseUtilities", daily_goods: "onboarding.expenseDailyGoods", clothing: "onboarding.expenseClothing", medical: "onboarding.expenseMedical", fitness: "onboarding.expenseFitness", entertainment: "onboarding.expenseEntertainment", subscriptions: "onboarding.expenseSubscriptions", education: "onboarding.expenseEducation", gifts: "onboarding.expenseGifts",
};

function categoryNames(categories: CategorySelection[], labelKeys: Record<string, string>) {
  return categories.flatMap((category) => category.customName?.trim() ? [category.customName.trim()] : category.templateKey && labelKeys[category.templateKey] ? [i18n.t(labelKeys[category.templateKey])] : []);
}

function TreeGroup({ label, children }: { label: string; children: string[] }) {
  if (!children.length) return null;
  return <div><p className="font-medium text-ink">{label}</p><ul className="mt-1.5 border-l border-line pl-3 text-stone">{children.map((child) => <li key={child} className="relative py-0.5 before:absolute before:-left-3 before:top-[0.8rem] before:h-px before:w-2 before:bg-line">{child}</li>)}</ul></div>;
}

function FinancialMap({ draft, columns = false }: { draft: OnboardingPayload; columns?: boolean }) {
  const funding = useMemo(() => Object.entries(fundingLabelKeys).map(([kind, key]) => ({ label: i18n.t(key), children: draft.fundingSpaces.filter((item) => item.kind === kind).map((item) => item.name) })).filter((group) => group.children.length), [draft]);
  const liabilities = draft.liabilities.map((item) => `${i18n.t(liabilityLabelKeys[item.kind])} · ${item.name}`);
  const income = categoryNames(draft.incomeCategories, incomeLabelKeys);
  const expense = categoryNames(draft.expenseCategories, expenseLabelKeys);
  return <div className={`grid gap-px overflow-hidden border border-line bg-line ${columns ? "sm:grid-cols-3" : "grid-cols-1"}`}>
    <section className="bg-paper p-4"><p className="ledger-label text-stone">{i18n.t("onboarding.fundingAccounts")}</p><div className="mt-3 space-y-3 text-sm">{funding.length ? funding.map((group) => <TreeGroup key={group.label} {...group} />) : <p className="text-stone">{i18n.t("onboarding.waiting")}</p>}</div></section>
    <section className="bg-paper p-4"><p className="ledger-label text-stone">{i18n.t("onboarding.incomeCategories")}</p><div className="mt-3 text-sm">{income.length ? <TreeGroup label={i18n.t("onboarding.recorded")} children={income} /> : <p className="text-stone">{i18n.t("onboarding.waiting")}</p>}</div></section>
    <section className="bg-paper p-4"><p className="ledger-label text-stone">{i18n.t("onboarding.expenseCategories")}</p><div className="mt-3 text-sm">{expense.length ? <TreeGroup label={i18n.t("onboarding.recorded")} children={expense} /> : <p className="text-stone">{i18n.t("onboarding.waiting")}</p>}{liabilities.length > 0 && <div className="mt-4"><TreeGroup label={i18n.t("onboarding.repayable")} children={liabilities} /></div>}</div></section>
  </div>;
}

function structureSummary(draft: OnboardingPayload) {
  const accounts = draft.fundingSpaces.length + draft.liabilities.length;
  return i18n.t("onboarding.structureSummary", { accounts, income: draft.incomeCategories.length, expense: draft.expenseCategories.length });
}

function StructureContent({ draft, columns = false }: { draft: OnboardingPayload; columns?: boolean }) {
  return <>
    <h3 className="text-lg font-semibold tracking-[-0.02em] text-ink">{draft.title}</h3>
    <p className="mt-1 text-xs leading-5 text-stone">{structureSummary(draft)}</p>
    <div className="mt-4"><FinancialMap draft={draft} columns={columns} /></div>
  </>;
}

export function OnboardingPrototype({ onCreate, creating = false, error = "", waiting = false }: { onCreate?: (payload: OnboardingPayload) => void; creating?: boolean; error?: string; waiting?: boolean }) {
  const { t } = useTranslation();
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState("");
  const [draft, setDraft] = useState<OnboardingPayload | null>(null);
  const [ready, setReady] = useState(false);
  const [planning, setPlanning] = useState(true);
  const [planError, setPlanError] = useState("");
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const conversationRef = useRef<HTMLDivElement>(null);
  const began = useRef(false);

  useEffect(() => {
    const previousOverflow = document.body.style.overflow;
    const previousPaddingBottom = document.body.style.paddingBottom;
    document.body.style.overflow = "hidden";
    document.body.style.paddingBottom = "0px";
    return () => {
      document.body.style.overflow = previousOverflow;
      document.body.style.paddingBottom = previousPaddingBottom;
    };
  }, []);

  async function askAgent(options: { start?: boolean; message?: string; history?: ChatMessage[]; currentDraft?: OnboardingPayload | null; currentReady?: boolean }) {
    setPlanError("");
    setPlanning(true);
    try {
      const response = await apiFetch("/api/onboarding/agent", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          start: options.start,
          message: options.message,
          messages: options.history ?? messages,
          draft: options.currentDraft ?? draft,
          ready: options.currentReady ?? ready,
        }),
      }, { kind: "write" });
      const result = await readLedgerAgentStream(response, {
        onMessageDelta: () => undefined,
        onOnboardingDraft: (event) => {
          setDraft(normalizeOnboardingDraft(event.draft as OnboardingPayload));
          setReady(event.ready);
        },
      });
      if (result.message.trim()) setMessages((current) => [...current, { role: "assistant", content: result.message.trim() }]);
    } catch (cause) {
      setPlanError(cause instanceof Error ? cause.message : t("onboarding.agentUnavailable"));
    } finally {
      setPlanning(false);
      requestAnimationFrame(() => inputRef.current?.focus());
    }
  }

  useEffect(() => {
    if (began.current) return;
    began.current = true;
    void askAgent({ start: true, history: [], currentDraft: null, currentReady: false });
  // The Agent begins exactly once. Subsequent turns explicitly carry their current draft and history.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    requestAnimationFrame(() => {
      const container = conversationRef.current;
      container?.scrollTo({ top: container.scrollHeight, behavior: messages.length > 1 ? "smooth" : "auto" });
    });
  }, [error, messages, planError, planning]);

  async function send() {
    const prompt = input.trim();
    if (!prompt || planning || waiting) return;
    const history = messages;
    const currentDraft = draft;
    const currentReady = ready;
    setMessages((current) => [...current, { role: "user", content: prompt }]);
    setInput("");
    await askAgent({ message: prompt, history, currentDraft, currentReady });
  }

  const createButton = draft && <button type="button" onClick={() => onCreate?.(draft)} disabled={creating || waiting || planning || !ready} className="inline-flex h-10 shrink-0 items-center justify-center gap-2 rounded-md bg-brand px-4 text-sm font-medium text-paper transition-transform active:scale-[0.98] disabled:opacity-50">{waiting ? t("onboarding.waitingVerify") : creating ? t("onboarding.creating") : t("onboarding.confirmCreate")}<ArrowRight className="h-4 w-4" /></button>;

  return <main className="h-dvh min-h-0 overflow-hidden bg-paper text-ink sm:p-4 lg:px-8 lg:py-6">
    <div className="mx-auto grid h-full min-h-0 max-w-7xl lg:grid-cols-[minmax(0,1fr)_360px] lg:gap-px lg:bg-line">
      <section className="flex h-full min-h-0 min-w-0 flex-col overflow-hidden border-x border-y border-line bg-panel lg:border-r-0">
        <header className="flex shrink-0 items-center justify-between border-b border-line bg-paper px-4 py-3 sm:px-6">
          <div className="flex min-w-0 items-center gap-3">
            <span className="grid h-9 w-9 shrink-0 place-items-center rounded-md bg-brand text-paper"><Bot className="h-4 w-4" /></span>
            <div className="min-w-0"><h1 className="truncate text-sm font-semibold text-ink">{t("onboarding.agentTitle")}</h1><p className="truncate text-xs text-stone">{planning ? t("onboarding.planningNext") : ready ? t("onboarding.readyAdjustable") : t("onboarding.guidingDesc")}</p></div>
          </div>
          <span className="shrink-0 text-xs tabular-nums text-stone">{ready ? t("onboarding.readyLabel") : planning ? t("onboarding.preparingLabel") : t("onboarding.guidingLabel")}</span>
        </header>

        {draft && <details className="group shrink-0 border-b border-line bg-paper lg:hidden">
          <summary className="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 px-4 py-2.5 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand/30">
            <span className="min-w-0"><span className="block text-sm font-medium text-ink">{t("onboarding.yourStructure")}</span><span className="block truncate text-xs text-stone">{structureSummary(draft)}</span></span>
            <span className="flex shrink-0 items-center gap-1 text-xs text-brand"><span className="group-open:hidden">{t("onboarding.view")}</span><span className="hidden group-open:inline">{t("onboarding.collapse")}</span><ChevronDown className="h-4 w-4 transition-transform group-open:rotate-180" /></span>
          </summary>
          <div className="max-h-[38dvh] overflow-y-auto overscroll-contain border-t border-line p-4"><StructureContent draft={draft} columns /></div>
        </details>}

        <div ref={conversationRef} className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 py-5 sm:px-6 sm:py-6">
          <div className="mx-auto max-w-3xl space-y-5">
            {messages.map((message, index) => <AgentMessageBubble key={`${message.role}-${index}`} role={message.role} content={message.content} />)}
            {planning && <div className="flex justify-start"><div className="inline-flex items-center gap-2 border border-line bg-paper px-4 py-3 text-sm text-stone"><LoaderCircle className="h-4 w-4 animate-spin text-brand" />{messages.length ? t("onboarding.responding") : t("onboarding.starting")}</div></div>}
            {(planError || error) && <p role="alert" className="border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger">{planError || error}</p>}
          </div>
        </div>

        <footer className="shrink-0 border-t border-line bg-paper px-4 py-3 sm:px-6">
          <div className="mx-auto max-w-3xl">
            <label className="sr-only" htmlFor="onboarding-agent-message">{t("onboarding.inputLabel")}</label>
            <div className="flex items-end gap-2"><textarea ref={inputRef} id="onboarding-agent-message" value={input} onChange={(event) => setInput(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); void send(); } }} placeholder={planning ? t("onboarding.agentPreparing") : t("onboarding.answerPlaceholder")} rows={2} disabled={planning || waiting} className="min-h-11 flex-1 resize-none rounded-md border border-line bg-panel px-3 py-2.5 text-sm leading-5 text-ink outline-none placeholder:text-stone focus-visible:ring-2 focus-visible:ring-brand/25 disabled:opacity-60" /><button type="button" onClick={() => void send()} disabled={!input.trim() || planning || waiting} className="grid h-11 w-11 shrink-0 place-items-center rounded-md bg-brand text-paper transition-transform active:scale-[0.98] disabled:opacity-50" aria-label={t("onboarding.sendLabel")}><Send className="h-4 w-4" /></button></div>
            {ready && draft && <div className="mt-3 flex items-center justify-between gap-3 border-t border-line pt-3 lg:hidden"><p className="flex min-w-0 items-center gap-2 text-xs text-stone"><CircleDollarSign className="h-4 w-4 shrink-0 text-brand" /><span className="truncate">{t("onboarding.canStillEdit")}</span></p>{createButton}</div>}
          </div>
        </footer>
      </section>

      <aside className="hidden min-h-0 flex-col overflow-hidden border border-line bg-paper lg:flex" aria-label={t("onboarding.realtimeStructure")}>
        <header className="shrink-0 border-b border-line px-5 py-4"><p className="text-sm font-semibold text-ink">{t("onboarding.yourStructure")}</p><p className="mt-1 text-xs leading-5 text-stone">{t("onboarding.realtimeDesc")}</p></header>
        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-5">{draft ? <StructureContent draft={draft} /> : <p className="text-sm leading-6 text-stone">{t("onboarding.structurePlaceholder")}</p>}</div>
        {ready && draft && <footer className="shrink-0 border-t border-line p-4"><p className="mb-3 flex items-start gap-2 text-xs leading-5 text-stone"><CircleDollarSign className="mt-0.5 h-4 w-4 shrink-0 text-brand" />{t("onboarding.confirmNote")}</p>{createButton}</footer>}
      </aside>
    </div>
  </main>;
}
