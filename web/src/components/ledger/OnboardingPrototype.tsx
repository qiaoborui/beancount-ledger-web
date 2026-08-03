import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowRight, Bot, CircleDollarSign, LoaderCircle, Send, Sparkles } from "lucide-react";
import { apiFetch } from "@/lib/apiEndpoints";

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

type OnboardingAgentResponse = { reply: string; draft: OnboardingPayload; ready: boolean };

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

function FinancialMap({ draft }: { draft: OnboardingPayload }) {
  const funding = useMemo(() => Object.entries(fundingLabels).map(([kind, label]) => ({ label, children: draft.fundingSpaces.filter((item) => item.kind === kind).map((item) => item.name) })).filter((group) => group.children.length), [draft]);
  const liabilities = draft.liabilities.map((item) => `${liabilityLabels[item.kind]} · ${item.name}`);
  const income = categoryNames(draft.incomeCategories, incomeLabels);
  const expense = categoryNames(draft.expenseCategories, expenseLabels);
  return <div className="mt-6 grid gap-px overflow-hidden border border-line bg-line sm:grid-cols-3"><section className="bg-paper p-4"><p className="ledger-label text-stone">钱在哪里</p><div className="mt-3 space-y-3 text-sm">{funding.map((group) => <TreeGroup key={group.label} {...group} />)}</div></section><section className="bg-paper p-4"><p className="ledger-label text-stone">钱从哪里来</p><div className="mt-3"><TreeGroup label="收入来源" children={income} /></div></section><section className="bg-paper p-4"><p className="ledger-label text-stone">钱去哪了</p><div className="mt-3"><TreeGroup label="消费分类" children={expense} />{liabilities.length > 0 && <div className="mt-4"><TreeGroup label="待还款项" children={liabilities} /></div>}</div></section></div>;
}

export function OnboardingPrototype({ onCreate, creating = false, error = "", waiting = false }: { onCreate?: (payload: OnboardingPayload) => void; creating?: boolean; error?: string; waiting?: boolean }) {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState("");
  const [draft, setDraft] = useState<OnboardingPayload | null>(null);
  const [ready, setReady] = useState(false);
  const [planning, setPlanning] = useState(true);
  const [planError, setPlanError] = useState("");
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const began = useRef(false);

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
      const result = await response.json() as OnboardingAgentResponse;
      setDraft(result.draft);
      setReady(result.ready);
      setMessages((current) => [...current, { role: "assistant", content: result.reply }]);
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

  const hasMap = Boolean(draft && (draft.fundingSpaces.length || draft.liabilities.length || draft.incomeCategories.length || draft.expenseCategories.length));

  return <main className="min-h-screen bg-paper px-4 py-5 text-ink sm:px-8 sm:py-8 lg:px-12 lg:py-10"><div className="mx-auto grid max-w-6xl gap-6 lg:grid-cols-[260px_minmax(0,1fr)] lg:gap-10">
    <aside className="lg:pt-5"><div className="border-b border-line pb-5 lg:border-0"><span className="grid h-10 w-10 place-items-center rounded-md bg-brand text-paper"><Bot className="h-5 w-5" /></span><p className="mt-5 ledger-label text-brand">你的第一本账</p><h1 className="mt-2 text-2xl font-semibold tracking-[-0.03em] text-ink">从一段引导开始</h1><p className="mt-2 max-w-xs text-sm leading-6 text-stone">不用认识账户科目。Agent 会主动问问题，把你的生活方式整理成一张可确认的财务地图。</p></div><div className="mt-6 border-l border-line pl-4 text-xs leading-5 text-stone"><p className="font-medium text-ink">创建前你始终能看到</p><p className="mt-1">钱在哪里、钱从哪里来、钱去哪了。确认后才会写入你的账本仓库并等待校验。</p></div></aside>
    <section className="flex min-h-[620px] flex-col border border-line bg-panel"><header className="flex items-center justify-between border-b border-line px-5 py-4 sm:px-8"><div className="flex items-center gap-2.5"><Sparkles className="h-4 w-4 text-brand" /><div><h2 className="text-sm font-semibold text-ink">建账 Agent</h2><p className="mt-0.5 text-xs text-stone">{planning ? "正在准备下一步" : ready ? "方案已准备好，仍可继续调整" : "一步步整理你的个人财务"}</p></div></div><span className="text-xs tabular-nums text-stone">{ready ? "可确认" : planning ? "准备中" : "引导中"}</span></header>
      <div className="min-h-0 flex-1 px-5 py-6 sm:px-8"><div className="mx-auto max-w-3xl space-y-5">{messages.map((message, index) => <div key={`${message.role}-${index}`} className={`flex ${message.role === "user" ? "justify-end" : "justify-start"}`}><div className={`max-w-[88%] rounded-md px-4 py-3 text-sm leading-6 ${message.role === "user" ? "bg-brand text-paper" : "border border-line bg-paper text-ink"}`}>{message.content}</div></div>)}{planning && <div className="flex justify-start"><div className="inline-flex items-center gap-2 border border-line bg-paper px-4 py-3 text-sm text-stone"><LoaderCircle className="h-4 w-4 animate-spin text-brand" />{messages.length ? "正在整理" : "正在开始"}</div></div>}{hasMap && draft && <div className="border-t border-line pt-6"><p className="ledger-label text-brand">你的财务地图</p><h3 className="mt-2 text-xl font-semibold tracking-[-0.025em] text-ink">{draft.title}</h3><p className="mt-2 text-sm text-stone">这是 Agent 目前理解的起点；想修改任何一项，直接告诉它。</p><FinancialMap draft={draft} /></div>}{(planError || error) && <p role="alert" className="text-sm text-danger">{planError || error}</p>}</div></div>
      <footer className="border-t border-line bg-paper px-5 py-4 sm:px-8"><div className="mx-auto max-w-3xl"><label className="sr-only" htmlFor="onboarding-agent-message">回答建账 Agent 的问题</label><div className="flex items-end gap-2"><textarea ref={inputRef} id="onboarding-agent-message" value={input} onChange={(event) => setInput(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); void send(); } }} placeholder={planning ? "Agent 正在准备…" : "回答上面的问题即可"} rows={2} disabled={planning || waiting} className="min-h-11 flex-1 resize-none rounded-md border border-line bg-panel px-3 py-2.5 text-sm leading-5 text-ink outline-none placeholder:text-stone focus-visible:ring-2 focus-visible:ring-brand/25 disabled:opacity-60" /><button type="button" onClick={() => void send()} disabled={!input.trim() || planning || waiting} className="grid h-11 w-11 shrink-0 place-items-center rounded-md bg-brand text-paper transition-transform active:scale-[0.98] disabled:opacity-50" aria-label="发送给建账 Agent"><Send className="h-4 w-4" /></button></div>{ready && draft && <div className="mt-4 flex flex-col-reverse gap-3 border-t border-line pt-4 sm:flex-row sm:items-center sm:justify-between"><p className="flex items-start gap-2 text-xs leading-5 text-stone"><CircleDollarSign className="mt-0.5 h-4 w-4 shrink-0 text-brand" />确认后会提交到你的账本仓库，后台校验失败时不会发布，也不会覆盖已有账本。</p><button type="button" onClick={() => onCreate?.(draft)} disabled={creating || waiting || planning} className="inline-flex h-10 shrink-0 items-center justify-center gap-2 rounded-md bg-brand px-4 text-sm font-medium text-paper transition-transform active:scale-[0.98] disabled:opacity-50">{waiting ? "正在等待校验…" : creating ? "正在创建…" : "确认并创建"}<ArrowRight className="h-4 w-4" /></button></div>}</div></footer>
    </section>
  </div></main>;
}
