import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowRight, Bot, ChevronDown, CircleDollarSign, LoaderCircle, Send } from "lucide-react";
import { apiFetch } from "@/lib/apiEndpoints";
import { readLedgerAgentStream } from "@/lib/ledgerAgentStream";
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

function normalizeOnboardingDraft(draft: OnboardingPayload): OnboardingPayload {
  return {
    ...draft,
    fundingSpaces: draft.fundingSpaces ?? [],
    liabilities: draft.liabilities ?? [],
    incomeCategories: draft.incomeCategories ?? [],
    expenseCategories: draft.expenseCategories ?? [],
  };
}

const fundingLabels: Record<FundingKind, string> = {
  cash: "现金",
  digital_wallet: "电子钱包",
  bank_card: "银行卡",
  savings: "储蓄",
  investment: "投资账户",
};

const liabilityLabels: Record<LiabilityKind, string> = {
  credit_card: "信用卡",
  consumer_loan: "消费贷",
  other_debt: "其他借款",
};

const incomeLabels: Record<string, string> = {
  salary: "工资", bonus: "奖金", freelance: "副业", interest: "利息", investment: "投资收益", other_income: "其他收入",
};

const expenseLabels: Record<string, string> = {
  groceries: "买菜", dining: "外出用餐", coffee: "咖啡饮品", public_transport: "公交地铁", taxi: "打车", rent: "房租", utilities: "水电燃气", daily_goods: "日用品", clothing: "衣物", medical: "医疗健康", fitness: "运动健身", entertainment: "娱乐", subscriptions: "订阅服务", education: "学习成长", gifts: "人情礼物",
};

function categoryNames(categories: CategorySelection[], labels: Record<string, string>) {
  return categories.flatMap((category) => category.customName?.trim() ? [category.customName.trim()] : category.templateKey && labels[category.templateKey] ? [labels[category.templateKey]] : []);
}

function TreeGroup({ label, children }: { label: string; children: string[] }) {
  if (!children.length) return null;
  return <div><p className="font-medium text-ink">{label}</p><ul className="mt-1.5 border-l border-line pl-3 text-stone">{children.map((child) => <li key={child} className="relative py-0.5 before:absolute before:-left-3 before:top-[0.8rem] before:h-px before:w-2 before:bg-line">{child}</li>)}</ul></div>;
}

function FinancialMap({ draft, columns = false }: { draft: OnboardingPayload; columns?: boolean }) {
  const funding = useMemo(() => Object.entries(fundingLabels).map(([kind, label]) => ({ label, children: draft.fundingSpaces.filter((item) => item.kind === kind).map((item) => item.name) })).filter((group) => group.children.length), [draft]);
  const liabilities = draft.liabilities.map((item) => `${liabilityLabels[item.kind]} · ${item.name}`);
  const income = categoryNames(draft.incomeCategories, incomeLabels);
  const expense = categoryNames(draft.expenseCategories, expenseLabels);
  return <div className={`grid gap-px overflow-hidden border border-line bg-line ${columns ? "sm:grid-cols-3" : "grid-cols-1"}`}>
    <section className="bg-paper p-4"><p className="ledger-label text-stone">资金账户</p><div className="mt-3 space-y-3 text-sm">{funding.length ? funding.map((group) => <TreeGroup key={group.label} {...group} />) : <p className="text-stone">等待整理</p>}</div></section>
    <section className="bg-paper p-4"><p className="ledger-label text-stone">收入分类</p><div className="mt-3 text-sm">{income.length ? <TreeGroup label="已记录" children={income} /> : <p className="text-stone">等待整理</p>}</div></section>
    <section className="bg-paper p-4"><p className="ledger-label text-stone">支出分类</p><div className="mt-3 text-sm">{expense.length ? <TreeGroup label="已记录" children={expense} /> : <p className="text-stone">等待整理</p>}{liabilities.length > 0 && <div className="mt-4"><TreeGroup label="待还款项" children={liabilities} /></div>}</div></section>
  </div>;
}

function structureSummary(draft: OnboardingPayload) {
  const accounts = draft.fundingSpaces.length + draft.liabilities.length;
  return `${accounts} 个账户 · ${draft.incomeCategories.length} 个收入分类 · ${draft.expenseCategories.length} 个支出分类`;
}

function StructureContent({ draft, columns = false }: { draft: OnboardingPayload; columns?: boolean }) {
  return <>
    <h3 className="text-lg font-semibold tracking-[-0.02em] text-ink">{draft.title}</h3>
    <p className="mt-1 text-xs leading-5 text-stone">{structureSummary(draft)}</p>
    <div className="mt-4"><FinancialMap draft={draft} columns={columns} /></div>
  </>;
}

export function OnboardingPrototype({ onCreate, creating = false, error = "", waiting = false }: { onCreate?: (payload: OnboardingPayload) => void; creating?: boolean; error?: string; waiting?: boolean }) {
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
      setPlanError(cause instanceof Error ? cause.message : "建账 Agent 暂时无法回应，请稍后重试。");
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

  const createButton = draft && <button type="button" onClick={() => onCreate?.(draft)} disabled={creating || waiting || planning || !ready} className="inline-flex h-10 shrink-0 items-center justify-center gap-2 rounded-md bg-brand px-4 text-sm font-medium text-paper transition-transform active:scale-[0.98] disabled:opacity-50">{waiting ? "正在等待校验…" : creating ? "正在创建…" : "确认并创建"}<ArrowRight className="h-4 w-4" /></button>;

  return <main className="h-dvh min-h-0 overflow-hidden bg-paper text-ink sm:p-4 lg:px-8 lg:py-6">
    <div className="mx-auto grid h-full min-h-0 max-w-7xl lg:grid-cols-[minmax(0,1fr)_360px] lg:gap-px lg:bg-line">
      <section className="flex h-full min-h-0 min-w-0 flex-col overflow-hidden border-x border-y border-line bg-panel lg:border-r-0">
        <header className="flex shrink-0 items-center justify-between border-b border-line bg-paper px-4 py-3 sm:px-6">
          <div className="flex min-w-0 items-center gap-3">
            <span className="grid h-9 w-9 shrink-0 place-items-center rounded-md bg-brand text-paper"><Bot className="h-4 w-4" /></span>
            <div className="min-w-0"><h1 className="truncate text-sm font-semibold text-ink">建账 Agent</h1><p className="truncate text-xs text-stone">{planning ? "正在准备下一步" : ready ? "方案已准备好，仍可继续调整" : "通过对话整理资金账户、收入分类和支出分类"}</p></div>
          </div>
          <span className="shrink-0 text-xs tabular-nums text-stone">{ready ? "可确认" : planning ? "准备中" : "引导中"}</span>
        </header>

        {draft && <details className="group shrink-0 border-b border-line bg-paper lg:hidden">
          <summary className="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 px-4 py-2.5 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand/30">
            <span className="min-w-0"><span className="block text-sm font-medium text-ink">你的账本结构</span><span className="block truncate text-xs text-stone">{structureSummary(draft)}</span></span>
            <span className="flex shrink-0 items-center gap-1 text-xs text-brand"><span className="group-open:hidden">查看</span><span className="hidden group-open:inline">收起</span><ChevronDown className="h-4 w-4 transition-transform group-open:rotate-180" /></span>
          </summary>
          <div className="max-h-[38dvh] overflow-y-auto overscroll-contain border-t border-line p-4"><StructureContent draft={draft} columns /></div>
        </details>}

        <div ref={conversationRef} className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 py-5 sm:px-6 sm:py-6">
          <div className="mx-auto max-w-3xl space-y-5">
            {messages.map((message, index) => <AgentMessageBubble key={`${message.role}-${index}`} role={message.role} content={message.content} />)}
            {planning && <div className="flex justify-start"><div className="inline-flex items-center gap-2 border border-line bg-paper px-4 py-3 text-sm text-stone"><LoaderCircle className="h-4 w-4 animate-spin text-brand" />{messages.length ? "正在整理" : "正在开始"}</div></div>}
            {(planError || error) && <p role="alert" className="border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger">{planError || error}</p>}
          </div>
        </div>

        <footer className="shrink-0 border-t border-line bg-paper px-4 py-3 sm:px-6">
          <div className="mx-auto max-w-3xl">
            <label className="sr-only" htmlFor="onboarding-agent-message">回答建账 Agent 的问题</label>
            <div className="flex items-end gap-2"><textarea ref={inputRef} id="onboarding-agent-message" value={input} onChange={(event) => setInput(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); void send(); } }} placeholder={planning ? "Agent 正在准备…" : "回答上面的问题即可"} rows={2} disabled={planning || waiting} className="min-h-11 flex-1 resize-none rounded-md border border-line bg-panel px-3 py-2.5 text-sm leading-5 text-ink outline-none placeholder:text-stone focus-visible:ring-2 focus-visible:ring-brand/25 disabled:opacity-60" /><button type="button" onClick={() => void send()} disabled={!input.trim() || planning || waiting} className="grid h-11 w-11 shrink-0 place-items-center rounded-md bg-brand text-paper transition-transform active:scale-[0.98] disabled:opacity-50" aria-label="发送给建账 Agent"><Send className="h-4 w-4" /></button></div>
            {ready && draft && <div className="mt-3 flex items-center justify-between gap-3 border-t border-line pt-3 lg:hidden"><p className="flex min-w-0 items-center gap-2 text-xs text-stone"><CircleDollarSign className="h-4 w-4 shrink-0 text-brand" /><span className="truncate">创建前仍可继续修改</span></p>{createButton}</div>}
          </div>
        </footer>
      </section>

      <aside className="hidden min-h-0 flex-col overflow-hidden border border-line bg-paper lg:flex" aria-label="实时账本结构">
        <header className="shrink-0 border-b border-line px-5 py-4"><p className="text-sm font-semibold text-ink">你的账本结构</p><p className="mt-1 text-xs leading-5 text-stone">独立于对话实时更新，不会遮挡 Agent 回复。</p></header>
        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-5">{draft ? <StructureContent draft={draft} /> : <p className="text-sm leading-6 text-stone">回答 Agent 的问题后，资金账户、收入分类和支出分类会显示在这里。</p>}</div>
        {ready && draft && <footer className="shrink-0 border-t border-line p-4"><p className="mb-3 flex items-start gap-2 text-xs leading-5 text-stone"><CircleDollarSign className="mt-0.5 h-4 w-4 shrink-0 text-brand" />确认后才会写入账本仓库；校验失败不会发布。</p>{createButton}</footer>}
      </aside>
    </div>
  </main>;
}
