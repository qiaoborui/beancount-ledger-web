import { useState } from "react";
import { ArrowLeft, ArrowRight, Banknote, Building2, Check, CircleDollarSign, Coffee, CreditCard, Landmark, Plus, ReceiptText, Smartphone, TrendingUp, WalletCards, X } from "lucide-react";

const steps = ["基本信息", "钱在哪里", "欠了多少钱", "收入来源", "消费去向", "确认创建"];

type FundingKind = "cash" | "bank_card" | "digital_wallet" | "savings" | "investment";
type LiabilityKind = "credit_card" | "consumer_loan" | "other_debt";
type FundingSpace = { id: string; kind: FundingKind; name: string; openingBalance: string; currency: string };
type Liability = { id: string; kind: LiabilityKind; name: string; openingBalance: string; currency: string };
type CategorySelection = { id: string; templateKey?: string; customName?: string };

export type OnboardingPayload = {
  title: string;
  currency: string;
  startDate: string;
  fundingSpaces: Omit<FundingSpace, "id">[];
  liabilities: Omit<Liability, "id">[];
  incomeCategories: Omit<CategorySelection, "id">[];
  expenseCategories: Omit<CategorySelection, "id">[];
};

type CategoryTemplate = { key: string; name: string; group?: string };

const fundingKinds: { kind: FundingKind; label: string; detail: string; icon: typeof WalletCards }[] = [
  { kind: "cash", label: "现金", detail: "钱包、备用现金", icon: Banknote },
  { kind: "bank_card", label: "银行卡", detail: "储蓄卡、活期账户", icon: Landmark },
  { kind: "digital_wallet", label: "电子钱包", detail: "微信、支付宝", icon: Smartphone },
  { kind: "savings", label: "储蓄", detail: "定期、存钱计划", icon: Building2 },
  { kind: "investment", label: "投资账户", detail: "先记录账户总额", icon: TrendingUp },
];

const liabilityKinds: { kind: LiabilityKind; label: string; detail: string }[] = [
  { kind: "credit_card", label: "信用卡", detail: "本期尚未偿还的账单" },
  { kind: "consumer_loan", label: "消费贷", detail: "分期、消费贷款" },
  { kind: "other_debt", label: "其他借款", detail: "需要归还的款项" },
];

const incomeTemplates: CategoryTemplate[] = [
  { key: "salary", name: "工资" }, { key: "bonus", name: "奖金" }, { key: "freelance", name: "副业" }, { key: "interest", name: "利息" }, { key: "investment", name: "投资收益" }, { key: "other_income", name: "其他收入" },
];

const expenseTemplates: CategoryTemplate[] = [
  { key: "groceries", name: "买菜", group: "吃喝" }, { key: "dining", name: "外出用餐", group: "吃喝" }, { key: "coffee", name: "咖啡饮品", group: "吃喝" },
  { key: "public_transport", name: "公交地铁", group: "出行" }, { key: "taxi", name: "打车", group: "出行" },
  { key: "rent", name: "房租", group: "居住" }, { key: "utilities", name: "水电燃气", group: "居住" },
  { key: "daily_goods", name: "日用品", group: "日常" }, { key: "clothing", name: "衣物", group: "日常" },
  { key: "medical", name: "医疗健康", group: "健康" }, { key: "fitness", name: "运动健身", group: "健康" },
  { key: "entertainment", name: "娱乐", group: "生活" }, { key: "subscriptions", name: "订阅服务", group: "生活" }, { key: "education", name: "学习成长", group: "生活" }, { key: "gifts", name: "人情礼物", group: "生活" },
];

let idSequence = 0;
const nextId = (prefix: string) => `${prefix}-${++idSequence}`;
const category = (templateKey?: string, customName?: string): CategorySelection => ({ id: nextId("category"), templateKey, customName });
const fundingSpace = (kind: FundingKind = "bank_card"): FundingSpace => ({ id: nextId("funding"), kind, name: "", openingBalance: "", currency: "" });
const liability = (kind: LiabilityKind = "credit_card"): Liability => ({ id: nextId("liability"), kind, name: "", openingBalance: "", currency: "" });

function kindLabel(kind: FundingKind | LiabilityKind) {
  return fundingKinds.find((item) => item.kind === kind)?.label ?? liabilityKinds.find((item) => item.kind === kind)?.label ?? "账户";
}

function selectedNames(selected: CategorySelection[], templates: CategoryTemplate[]) {
  return selected.flatMap((item) => {
    if (item.customName?.trim()) return [item.customName.trim()];
    const template = templates.find((candidate) => candidate.key === item.templateKey);
    return template ? [template.name] : [];
  });
}

function CategoryPicker({ title, detail, templates, selected, setSelected }: { title: string; detail: string; templates: CategoryTemplate[]; selected: CategorySelection[]; setSelected: (value: CategorySelection[]) => void }) {
  const toggle = (templateKey: string) => setSelected(selected.some((item) => item.templateKey === templateKey) ? selected.filter((item) => item.templateKey !== templateKey) : [...selected, category(templateKey)]);
  const addCustom = () => setSelected([...selected, category(undefined, "")]);
  const updateCustom = (id: string, customName: string) => setSelected(selected.map((item) => item.id === id ? { ...item, customName } : item));
  const remove = (id: string) => setSelected(selected.filter((item) => item.id !== id));
  return <div className="max-w-3xl"><p className="text-sm text-stone">{detail}</p><div className="mt-7 flex flex-wrap gap-2">{templates.map((item) => {
    const active = selected.some((entry) => entry.templateKey === item.key);
    return <button key={item.key} type="button" aria-pressed={active} onClick={() => toggle(item.key)} className={`inline-flex min-h-10 items-center gap-2 rounded-md border px-3 py-2 text-left text-sm transition ${active ? "border-brand bg-tag text-ink" : "border-line bg-paper text-stone hover:border-brand/40 hover:text-ink"}`}><span className={`grid h-4 w-4 place-items-center rounded-sm border ${active ? "border-brand bg-brand text-paper" : "border-line"}`}>{active && <Check className="h-3 w-3" />}</span>{item.name}</button>;
  })}</div><div className="mt-6 border-t border-line pt-5"><div className="flex items-center justify-between gap-4"><div><h3 className="text-sm font-semibold text-ink">也可以加自己的分类</h3><p className="mt-1 text-xs text-stone">用你习惯的叫法即可，之后可随时调整。</p></div><button type="button" onClick={addCustom} className="inline-flex h-9 shrink-0 items-center gap-1.5 rounded-md border border-line bg-paper px-3 text-xs font-medium text-brand hover:bg-tag"><Plus className="h-3.5 w-3.5" />添加</button></div>{selected.filter((item) => item.customName !== undefined).map((item) => <div key={item.id} className="mt-3 flex items-center gap-2"><input value={item.customName} onChange={(event) => updateCustom(item.id, event.target.value)} placeholder={`例如${title === "收入来源" ? "项目奖金" : "宠物"}`} className="h-10 min-w-0 flex-1 rounded-md border border-line bg-paper px-3 text-sm text-ink outline-none focus-visible:ring-2 focus-visible:ring-brand/25" /><button type="button" onClick={() => remove(item.id)} className="grid h-10 w-10 place-items-center rounded-md text-stone hover:bg-tag hover:text-ink" aria-label="删除自定义分类"><X className="h-4 w-4" /></button></div>)}</div></div>;
}

export function OnboardingPrototype({ onCreate, creating = false, error = "", waiting = false }: { onCreate?: (payload: OnboardingPayload) => void; creating?: boolean; error?: string; waiting?: boolean }) {
  const [step, setStep] = useState(0);
  const [title, setTitle] = useState("我的生活账本");
  const [currency, setCurrency] = useState("CNY");
  const [startDate, setStartDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [fundingSpaces, setFundingSpaces] = useState<FundingSpace[]>([{ ...fundingSpace("cash"), name: "钱包" }, { ...fundingSpace("bank_card"), name: "常用银行卡" }]);
  const [liabilities, setLiabilities] = useState<Liability[]>([]);
  const [incomeCategories, setIncomeCategories] = useState<CategorySelection[]>([category("salary")]);
  const [expenseCategories, setExpenseCategories] = useState<CategorySelection[]>([category("groceries"), category("dining"), category("public_transport"), category("rent"), category("daily_goods"), category("entertainment")]);

  const updateFunding = (id: string, patch: Partial<FundingSpace>) => setFundingSpaces((items) => items.map((item) => item.id === id ? { ...item, ...patch } : item));
  const updateLiability = (id: string, patch: Partial<Liability>) => setLiabilities((items) => items.map((item) => item.id === id ? { ...item, ...patch } : item));
  const activeFundingSpaces = fundingSpaces.filter((item) => item.name.trim());
  const activeLiabilities = liabilities.filter((item) => item.name.trim());
  const canContinue = step !== 0 || Boolean(title.trim() && currency && startDate);
  const canCreate = activeFundingSpaces.length > 0;
  const create = () => onCreate?.({ title: title.trim(), currency, startDate, fundingSpaces: activeFundingSpaces.map(({ id: _id, ...item }) => item), liabilities: activeLiabilities.map(({ id: _id, ...item }) => item), incomeCategories: incomeCategories.filter((item) => item.templateKey || item.customName?.trim()).map(({ id: _id, ...item }) => ({ ...item, customName: item.customName?.trim() })), expenseCategories: expenseCategories.filter((item) => item.templateKey || item.customName?.trim()).map(({ id: _id, ...item }) => ({ ...item, customName: item.customName?.trim() })) });
  const continueFlow = () => { if (!canContinue || waiting) return; if (step === 5) { if (canCreate) create(); return; } setStep((current) => Math.min(5, current + 1)); };

  return <main className="min-h-screen bg-paper px-4 py-5 text-ink sm:px-8 sm:py-8 lg:px-12 lg:py-10"><div className="mx-auto grid max-w-6xl gap-6 lg:grid-cols-[232px_minmax(0,1fr)] lg:gap-10">
    <aside className="lg:pt-4"><div className="border-b border-line pb-5 lg:border-0 lg:pb-0"><p className="ledger-label text-brand">你的第一本账</p><h1 className="mt-2 text-2xl font-semibold tracking-[-0.03em] text-ink">从一张财务地图开始</h1><p className="mt-2 max-w-xs text-sm leading-6 text-stone">不用学习会计术语，先把你的钱、收入和日常消费放到熟悉的位置。</p></div><ol className="mt-5 grid grid-cols-3 gap-x-2 gap-y-3 sm:grid-cols-6 lg:mt-9 lg:grid-cols-1 lg:gap-3">{steps.map((label, index) => <li key={label} className={`flex min-w-0 items-center gap-2.5 text-xs lg:text-sm ${index === step ? "font-semibold text-ink" : index < step ? "text-olive" : "text-stone"}`}><span className={`grid h-6 w-6 shrink-0 place-items-center rounded-full text-[11px] ${index < step ? "bg-olive text-paper" : index === step ? "bg-brand text-paper" : "bg-tag"}`}>{index < step ? <Check className="h-3.5 w-3.5" /> : index + 1}</span><span className="truncate">{label}</span></li>)}</ol></aside>
    <section className="min-h-[620px] border border-line bg-panel"><div className="border-b border-line px-5 py-4 sm:px-8"><div className="flex items-center justify-between gap-4"><p className="text-sm font-medium text-ink">{steps[step]}</p><p className="text-xs tabular-nums text-stone">{step + 1} / {steps.length}</p></div><div className="mt-3 h-1 bg-line"><div className="h-full bg-brand transition-[width] duration-200" style={{ width: `${((step + 1) / steps.length) * 100}%` }} /></div></div>
      <div className="px-5 py-7 sm:px-8 sm:py-9">
        {step === 0 && <div className="max-w-xl"><p className="text-sm text-stone">只需确认这本账的基本信息，之后随时可以修改。</p><h2 className="mt-2 text-2xl font-semibold tracking-[-0.03em] text-ink">这本账怎么称呼？</h2><label className="mt-8 block text-sm font-medium text-ink">账本名称<input value={title} onChange={(event) => setTitle(event.target.value)} className="mt-2 h-11 w-full rounded-md border border-line bg-paper px-3 text-sm outline-none focus-visible:ring-2 focus-visible:ring-brand/25" /></label><div className="mt-5 grid gap-4 sm:grid-cols-2"><label className="block text-sm font-medium text-ink">日常记账货币<select value={currency} onChange={(event) => setCurrency(event.target.value)} className="mt-2 h-11 w-full rounded-md border border-line bg-paper px-3 text-sm"><option value="CNY">CNY，人民币</option><option value="USD">USD，美元</option><option value="HKD">HKD，港币</option></select></label><label className="block text-sm font-medium text-ink">从哪天开始<input type="date" value={startDate} onChange={(event) => setStartDate(event.target.value)} className="mt-2 h-11 w-full rounded-md border border-line bg-paper px-3 text-sm" /></label></div></div>}
        {step === 1 && <div className="max-w-3xl"><p className="text-sm text-stone">你的钱现在放在哪里？每个位置可以填写当前余额，也可以先留空。</p><h2 className="mt-2 text-2xl font-semibold tracking-[-0.03em] text-ink">钱在哪里</h2><div className="mt-7 space-y-3">{fundingSpaces.map((item) => <div key={item.id} className="grid gap-3 border border-line bg-paper p-3 sm:grid-cols-[140px_minmax(0,1fr)_120px_40px]"><label className="sr-only">资金空间类型</label><select value={item.kind} onChange={(event) => updateFunding(item.id, { kind: event.target.value as FundingKind })} className="h-10 rounded-md border border-line bg-panel px-2.5 text-sm text-ink">{fundingKinds.map((kind) => <option key={kind.kind} value={kind.kind}>{kind.label}</option>)}</select><input value={item.name} onChange={(event) => updateFunding(item.id, { name: event.target.value })} placeholder="例如：招商银行卡" aria-label="资金空间名称" className="h-10 min-w-0 rounded-md border border-line bg-panel px-3 text-sm outline-none focus-visible:ring-2 focus-visible:ring-brand/25" /><input value={item.openingBalance} onChange={(event) => updateFunding(item.id, { openingBalance: event.target.value })} inputMode="decimal" placeholder="当前余额" aria-label="当前余额" className="h-10 rounded-md border border-line bg-panel px-3 text-sm tabular-nums outline-none focus-visible:ring-2 focus-visible:ring-brand/25" /><button type="button" onClick={() => setFundingSpaces((items) => items.filter((entry) => entry.id !== item.id))} disabled={fundingSpaces.length === 1} className="grid h-10 w-10 place-items-center rounded-md text-stone hover:bg-tag hover:text-ink disabled:opacity-30" aria-label="删除资金空间"><X className="h-4 w-4" /></button></div>)}</div><div className="mt-4 flex flex-wrap gap-2">{fundingKinds.map((item) => <button key={item.kind} type="button" onClick={() => setFundingSpaces((items) => [...items, fundingSpace(item.kind)])} className="inline-flex h-9 items-center gap-1.5 rounded-md border border-line bg-paper px-3 text-xs font-medium text-brand hover:bg-tag"><Plus className="h-3.5 w-3.5" />添加{item.label}</button>)}</div><p className="mt-5 text-xs leading-5 text-stone">投资账户第一版只记录账户总额，不包含持仓和汇率明细。</p></div>}
        {step === 2 && <div className="max-w-3xl"><p className="text-sm text-stone">如果暂时没有欠款，直接继续即可。请填写你目前还需要偿还的金额。</p><h2 className="mt-2 text-2xl font-semibold tracking-[-0.03em] text-ink">欠了多少钱</h2>{liabilities.length === 0 ? <div className="mt-7 border border-dashed border-line bg-paper px-4 py-5"><div className="flex items-start gap-3"><CreditCard className="mt-0.5 h-5 w-5 text-brand" /><div><p className="text-sm font-medium text-ink">没有欠款也完全没问题</p><p className="mt-1 text-xs leading-5 text-stone">信用卡、分期或借款都可以日后再添加。</p></div></div></div> : <div className="mt-7 space-y-3">{liabilities.map((item) => <div key={item.id} className="grid gap-3 border border-line bg-paper p-3 sm:grid-cols-[140px_minmax(0,1fr)_120px_40px]"><select value={item.kind} onChange={(event) => updateLiability(item.id, { kind: event.target.value as LiabilityKind })} className="h-10 rounded-md border border-line bg-panel px-2.5 text-sm text-ink">{liabilityKinds.map((kind) => <option key={kind.kind} value={kind.kind}>{kind.label}</option>)}</select><input value={item.name} onChange={(event) => updateLiability(item.id, { name: event.target.value })} placeholder="例如：招商信用卡" aria-label="欠款账户名称" className="h-10 min-w-0 rounded-md border border-line bg-panel px-3 text-sm outline-none focus-visible:ring-2 focus-visible:ring-brand/25" /><input value={item.openingBalance} onChange={(event) => updateLiability(item.id, { openingBalance: event.target.value })} inputMode="decimal" placeholder="待还金额" aria-label="待还金额" className="h-10 rounded-md border border-line bg-panel px-3 text-sm tabular-nums outline-none focus-visible:ring-2 focus-visible:ring-brand/25" /><button type="button" onClick={() => setLiabilities((items) => items.filter((entry) => entry.id !== item.id))} className="grid h-10 w-10 place-items-center rounded-md text-stone hover:bg-tag hover:text-ink" aria-label="删除欠款账户"><X className="h-4 w-4" /></button></div>)}</div>}<div className="mt-4 flex flex-wrap gap-2">{liabilityKinds.map((item) => <button key={item.kind} type="button" onClick={() => setLiabilities((items) => [...items, liability(item.kind)])} className="inline-flex h-9 items-center gap-1.5 rounded-md border border-line bg-paper px-3 text-xs font-medium text-brand hover:bg-tag"><Plus className="h-3.5 w-3.5" />添加{item.label}</button>)}</div></div>}
        {step === 3 && <div><h2 className="text-2xl font-semibold tracking-[-0.03em] text-ink">钱从哪里来</h2><CategoryPicker title="收入来源" detail="先选常见来源，系统会为它们准备好。没有的可以直接用自己的叫法添加。" templates={incomeTemplates} selected={incomeCategories} setSelected={setIncomeCategories} /></div>}
        {step === 4 && <div><h2 className="text-2xl font-semibold tracking-[-0.03em] text-ink">钱花到哪里去</h2><CategoryPicker title="消费分类" detail="按生活场景选就好。以后记一笔消费时，系统会用这些分类帮助你归类。" templates={expenseTemplates} selected={expenseCategories} setSelected={setExpenseCategories} /></div>}
        {step === 5 && <div className="max-w-3xl"><p className="text-sm text-stone">下面是你即将拥有的个人财务地图。</p><h2 className="mt-2 text-2xl font-semibold tracking-[-0.03em] text-ink">确认并创建</h2><div className="mt-7 divide-y divide-line border border-line bg-paper"><div className="grid gap-3 p-4 sm:grid-cols-[150px_1fr]"><p className="ledger-label text-stone">钱在哪里</p><div className="flex flex-wrap gap-2">{activeFundingSpaces.map((item) => <span key={item.id} className="rounded-full bg-tag px-2.5 py-1 text-sm text-ink">{kindLabel(item.kind)} · {item.name}</span>)}{activeFundingSpaces.length === 0 && <span className="text-sm text-danger">请至少保留一个资金位置</span>}</div></div><div className="grid gap-3 p-4 sm:grid-cols-[150px_1fr]"><p className="ledger-label text-stone">欠了多少钱</p><p className="text-sm text-ink">{activeLiabilities.length ? activeLiabilities.map((item) => `${kindLabel(item.kind)} · ${item.name}`).join("、") : "暂不记录"}</p></div><div className="grid gap-3 p-4 sm:grid-cols-[150px_1fr]"><p className="ledger-label text-stone">收入来源</p><p className="text-sm text-ink">{selectedNames(incomeCategories, incomeTemplates).join("、") || "暂不预设"}</p></div><div className="grid gap-3 p-4 sm:grid-cols-[150px_1fr]"><p className="ledger-label text-stone">消费去向</p><p className="text-sm text-ink">{selectedNames(expenseCategories, expenseTemplates).join("、") || "暂不预设"}</p></div></div><div className="mt-5 flex gap-3 border-l border-brand pl-3"><CircleDollarSign className="mt-0.5 h-4 w-4 shrink-0 text-brand" /><p className="text-xs leading-5 text-stone">创建后会提交到你的账本仓库，再由后台校验服务检查。校验失败不会发布到主界面，现有账本也不会被覆盖。</p></div>{waiting && <div className="mt-5 border border-brand/25 bg-tag p-4"><div className="flex items-center gap-3"><ReceiptText className="h-4 w-4 text-brand" /><div><p className="text-sm font-medium text-ink">正在准备你的财务地图</p><p className="mt-1 text-xs text-stone">已提交，正在等待后台校验通过。</p></div></div><div className="mt-3 h-1 overflow-hidden bg-line"><div className="h-full w-4/5 animate-pulse bg-brand" /></div></div>}</div>}
        {error && <p role="alert" className="mt-5 text-sm text-danger">{error}</p>}
      </div>
      <div className="mt-auto flex items-center justify-between border-t border-line px-5 py-4 sm:px-8"><button type="button" onClick={() => setStep((current) => Math.max(0, current - 1))} disabled={step === 0 || waiting} className="inline-flex h-10 items-center gap-1.5 rounded-md px-2 text-sm text-stone hover:bg-tag hover:text-ink disabled:opacity-0"><ArrowLeft className="h-4 w-4" />上一步</button><button type="button" onClick={continueFlow} disabled={!canContinue || (step === 5 && !canCreate) || creating || waiting} className="inline-flex h-10 items-center gap-2 rounded-md bg-brand px-4 text-sm font-medium text-paper transition-transform active:scale-[0.98] disabled:opacity-50">{step === 5 ? (waiting ? "正在等待校验…" : creating ? "正在创建…" : "创建账本") : "继续"}<ArrowRight className="h-4 w-4" /></button></div>
    </section>
  </div></main>;
}
