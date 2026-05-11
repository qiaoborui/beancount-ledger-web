import { Agent, OpenAIProvider, Runner } from "@openai/agents";
import { monthSummary, parseAccounts, parseTransactions } from "./beancountParser";
import { ParsedTransactionsSchema, type ParsedTransaction } from "./schemas";

export type BookkeepingChatMessage = { role: "user" | "assistant"; text: string };

export type BookkeepingChatResult = {
  message: string;
  entries: ParsedTransaction[];
};

function moneyToNumber(value: string) {
  return Number(value);
}

function validateEntry(entry: ParsedTransaction, accounts: string[], index: number) {
  const accountSet = new Set(accounts);
  const invalid = entry.postings.filter((posting) => !accountSet.has(posting.account)).map((posting) => posting.account);
  if (invalid.length) throw new Error(`第 ${index + 1} 条 AI 使用了不存在的账户：${invalid.join(", ")}`);

  const total = entry.postings.reduce((sum, posting) => sum + moneyToNumber(posting.amount), 0);
  if (Math.abs(total) >= 0.005) {
    throw new Error(`第 ${index + 1} 条 AI 生成的分录不平衡，差额 ${total.toFixed(2)} CNY`);
  }
}

function normalizeAndValidateEntries(parsed: unknown, accounts: string[]): ParsedTransaction[] {
  const result = ParsedTransactionsSchema.parse(parsed);
  result.entries.forEach((entry, index) => validateEntry(entry, accounts, index));
  return result.entries;
}

function normalizeOptionalEntries(parsed: unknown, accounts: string[]): ParsedTransaction[] {
  const result = (parsed as { entries?: unknown }).entries;
  const entries = Array.isArray(result) ? result : [];
  return entries.map((entry, index) => {
    const parsedEntry = ParsedTransactionsSchema.shape.entries.element.parse(entry);
    validateEntry(parsedEntry, accounts, index);
    return parsedEntry;
  });
}

function extractJson(content: string) {
  const trimmed = content.trim();
  if (trimmed.startsWith("{") && trimmed.endsWith("}")) return JSON.parse(trimmed);
  const match = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/) ?? trimmed.match(/(\{[\s\S]*\})/);
  if (!match) throw new Error("AI 没有返回 JSON");
  return JSON.parse(match[1]);
}

const parsedTransactionsJsonSchema = {
  type: "object",
  additionalProperties: false,
  required: ["entries"],
  properties: {
    entries: {
      type: "array",
      minItems: 1,
      items: {
        type: "object",
        additionalProperties: false,
        required: ["kind", "date", "payee", "narration", "metadata", "tags", "postings", "confidence", "needsReview", "questions"],
        properties: {
          kind: { type: "string", enum: ["transaction"] },
          date: { type: "string", pattern: "^\\d{4}-\\d{2}-\\d{2}$" },
          payee: { type: "string", minLength: 1 },
          narration: { type: "string" },
          metadata: {
            type: "object",
            additionalProperties: { anyOf: [{ type: "string" }, { type: "number" }, { type: "boolean" }] },
          },
          tags: { type: "array", items: { type: "string", pattern: "^[A-Za-z0-9_-]+$" } },
          postings: {
            type: "array",
            minItems: 2,
            items: {
              type: "object",
              additionalProperties: false,
              required: ["account", "amount", "currency"],
              properties: {
                account: { type: "string", minLength: 1 },
                amount: { type: "string", pattern: "^-?\\d+(\\.\\d{1,2})?$" },
                currency: { type: "string", enum: ["CNY"] },
              },
            },
          },
          confidence: { type: "number", minimum: 0, maximum: 1 },
          needsReview: { type: "boolean" },
          questions: { type: "array", items: { type: "string" } },
        },
      },
    },
  },
} as const;

const bookkeepingChatJsonSchema = {
  type: "object",
  additionalProperties: false,
  required: ["message", "entries"],
  properties: {
    message: { type: "string" },
    entries: { ...parsedTransactionsJsonSchema.properties.entries, minItems: 0 },
  },
} as const;

function activeAccountNames() {
  return parseAccounts().filter((account) => account.active).map((account) => account.account);
}

function yuan(cents: number) {
  return Number((cents / 100).toFixed(2));
}

function addDays(date: Date, days: number) {
  const next = new Date(date);
  next.setUTCDate(next.getUTCDate() + days);
  return next;
}

function formatDate(date: Date) {
  return date.toISOString().slice(0, 10);
}

function monthRange(month: string) {
  const [year, monthNumber] = month.split("-").map(Number);
  const start = `${month}-01`;
  const endDate = monthNumber === 12 ? new Date(Date.UTC(year + 1, 0, 1)) : new Date(Date.UTC(year, monthNumber, 1));
  return { start, end: formatDate(endDate) };
}

function previousMonth(month: string) {
  const [year, monthNumber] = month.split("-").map(Number);
  const date = new Date(Date.UTC(year, monthNumber - 2, 1));
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
}

function inferQueryRange(message: string, today: string) {
  const thisMonth = today.slice(0, 7);
  if (/上月|上个月/.test(message)) return { label: "上月", ...monthRange(previousMonth(thisMonth)) };
  if (/最近(一周|7天|七天)|近(一周|7天|七天)|本周|这周|这个周/.test(message)) return { label: /本周|这周|这个周/.test(message) ? "本周" : "最近 7 天", start: formatDate(addDays(new Date(`${today}T00:00:00.000Z`), -6)), end: formatDate(addDays(new Date(`${today}T00:00:00.000Z`), 1)) };
  if (/今天/.test(message)) return { label: "今天", start: today, end: formatDate(addDays(new Date(`${today}T00:00:00.000Z`), 1)) };
  if (/昨天/.test(message)) {
    const yesterday = formatDate(addDays(new Date(`${today}T00:00:00.000Z`), -1));
    return { label: "昨天", start: yesterday, end: today };
  }
  return { label: "本月", ...monthRange(thisMonth) };
}

const queryKeywordRules: { re: RegExp; accounts: string[]; label: string }[] = [
  { re: /咖啡|星巴克|瑞幸|饮品|奶茶|可乐|饮料/, accounts: ["Expenses:Food:Drinks"], label: "咖啡/饮品" },
  { re: /餐|饭|外卖|午餐|晚餐|早餐|吃/, accounts: ["Expenses:Food:Meals"], label: "餐饮" },
  { re: /超市|生鲜|买菜| groceries?/i, accounts: ["Expenses:Food:Groceries"], label: "生鲜/超市" },
  { re: /交通|打车|滴滴|地铁|公交|停车|租车/, accounts: ["Expenses:Transport:Public", "Expenses:Transport:Taxi", "Expenses:Transport:Parking", "Expenses:Transport:CarRental", "Expenses:Transport:Other"], label: "交通/出行" },
  { re: /购物|网购|淘宝|京东|拼多多|日用品|衣服|电脑|配件|送礼/, accounts: ["Expenses:Shopping:Daily", "Expenses:Shopping:Clothing", "Expenses:Shopping:Electronics", "Expenses:Shopping:Gifts", "Expenses:Shopping:Other"], label: "购物" },
  { re: /订阅|软件|会员|数字/, accounts: ["Expenses:Digital:Subscription", "Expenses:Digital:Devices"], label: "订阅/软件" },
  { re: /房租|物业|水电|电费|水费|燃气|住房|管理费/, accounts: ["Expenses:Housing:Rent", "Expenses:Housing:Utilities", "Expenses:Housing:Property", "Expenses:Housing:Other"], label: "住房" },
  { re: /医疗|医院|药|健康/, accounts: ["Expenses:Health:Medical", "Expenses:Health:Pharmacy"], label: "医疗健康" },
  { re: /娱乐|电影|游戏/, accounts: ["Expenses:Entertainment"], label: "娱乐" },
  { re: /旅行|酒店|旅游|机票|高铁/, accounts: ["Expenses:Travel"], label: "旅行" },
  { re: /红包|礼金|随礼|人情|请客|应酬|母亲节|生日/, accounts: ["Expenses:Social:RedPacket", "Expenses:Social:Gift", "Expenses:Social:Treat"], label: "人情往来" },
  { re: /电话|话费|流量|宽带|网络/, accounts: ["Expenses:Communication:Mobile", "Expenses:Communication:Internet"], label: "通讯" },
];

function isLedgerQuery(message: string) {
  const hasAmount = /\d+(?:\.\d+)?/.test(message);
  const questionLike = /(多少|花了多少|共花|总共|合计|消费多少|支出多少|收入多少|统计|汇总|最多|哪些|明细|账单|所有消费|全部消费)/.test(message);
  const rangeOnlyQuery = /(最近|本周|这周|这个周|本月|这个月|上月|上个月|今天|昨天).*(消费|支出|收入)/.test(message);
  return questionLike || (!hasAmount && rangeOnlyQuery);
}

function buildLedgerQueryContext(message: string, today: string) {
  if (!isLedgerQuery(message)) return "";

  const range = inferQueryRange(message, today);
  const txns = parseTransactions().filter((txn) => txn.date >= range.start && txn.date < range.end);
  const matchedRule = queryKeywordRules.find((rule) => rule.re.test(message));
  const matchedAccounts = new Set(matchedRule?.accounts ?? []);
  const relevant = txns.filter((txn) => {
    if (!matchedRule) return true;
    const metadataText = Object.entries(txn.metadata ?? {}).map(([key, value]) => `${key}:${String(value)}`).join(" ");
    const haystack = `${txn.payee} ${txn.narration} ${metadataText} ${(txn.tags ?? []).join(" ")} ${txn.postings.map((posting) => posting.account).join(" ")}`;
    return matchedRule.re.test(haystack) || txn.postings.some((posting) => matchedAccounts.has(posting.account));
  });

  const expenseByAccount: Record<string, number> = {};
  let totalExpense = 0;
  let totalIncome = 0;
  for (const txn of relevant) {
    for (const posting of txn.postings) {
      if (posting.account.startsWith("Expenses:")) {
        if (matchedRule && !matchedAccounts.has(posting.account) && !matchedRule.re.test(`${txn.payee} ${txn.narration} ${Object.entries(txn.metadata ?? {}).map(([key, value]) => `${key}:${String(value)}`).join(" ")}`)) continue;
        totalExpense += posting.amount;
        expenseByAccount[posting.account] = (expenseByAccount[posting.account] ?? 0) + posting.amount;
      }
      if (!matchedRule && posting.account.startsWith("Income:")) totalIncome += Math.abs(posting.amount);
    }
  }

  const currentMonth = today.slice(0, 7);
  const summary = monthSummary(currentMonth, parseTransactions());
  return JSON.stringify({
    range,
    filter: matchedRule?.label ?? "全部相关账目",
    totals: { expenseCNY: yuan(totalExpense), incomeCNY: yuan(totalIncome) },
    expenseByAccountCNY: Object.fromEntries(Object.entries(expenseByAccount).sort((a, b) => b[1] - a[1]).map(([account, amount]) => [account, yuan(amount)])),
    matchedTransactions: relevant.slice(-40).map((txn) => ({
      date: txn.date,
      payee: txn.payee,
      narration: txn.narration,
      metadata: txn.metadata,
      tags: txn.tags,
      expenses: txn.postings.filter((posting) => posting.account.startsWith("Expenses:")).map((posting) => ({ account: posting.account, amountCNY: yuan(posting.amount) })),
    })),
    currentMonthSummaryCNY: {
      month: currentMonth,
      income: yuan(summary.income),
      expense: yuan(summary.expense),
      topCategories: Object.entries(summary.categories).sort((a, b) => b[1] - a[1]).slice(0, 8).map(([account, amount]) => ({ account, amountCNY: yuan(amount) })),
    },
  }, null, 2);
}

function parserInstructions(today: string, accounts: string[]) {
  return `你是一个 Beancount 记账解析器。只输出 JSON，不要输出 Markdown，不要解释。
今天日期：${today}
币种固定为 CNY。
只能使用下面账户白名单，不允许创造新账户：
${accounts.map((a) => `- ${a}`).join("\n")}

输出 JSON Schema：
{
  "entries": [
    {
      "kind": "transaction",
      "date": "YYYY-MM-DD",
      "payee": "商户/对方",
      "narration": "简短说明",
      "metadata": {"platform":"taobao/pdd/jd/meituan/eleme/wechat/alipay/offline 等", "channel":"online/offline/transfer/subscription", "person":"对方", "event":"事件", "purpose":"用途"},
      "tags": ["少量稳定专题标签，不含 #"],
      "postings": [{"account": "账户白名单之一", "amount": "两位小数字符串", "currency": "CNY"}],
      "confidence": 0.0-1.0,
      "needsReview": true/false,
      "questions": ["不确定时给问题"]
    }
  ]
}

规则：
1. 根对象必须是 {"entries": [...]}；entries 至少 1 条。
2. 输入可能是一句话、多行流水、短信/账单片段；每一笔独立消费/收入/转账都生成一个 entry。
3. 不要把多笔消费合并成一条；同一行包含多笔时也要拆成多条。
4. 每个 entry 的 kind 固定为 transaction。
5. 金额必须是字符串，例如 "38.00"，不要用数字 38。
6. 每个 entry 的 postings 金额合计必须严格等于 0。
7. 信用卡消费：Liabilities 开头的信用卡账户为负数，Expenses 开头的支出分类为正数。
8. 储蓄卡/微信/支付宝消费：Assets 开头的资产账户为负数，Expenses 为正数。
9. 收入：Assets 开头的资产账户正数，Income 开头的收入分类为负数。
10. 信用卡还款：Assets 资产账户负数，Liabilities 信用卡账户正数。
11. 代付/AA：付款资产账户记录总付款负数，个人承担记 Expenses，待收部分记 Assets 下 Receivable 相关账户。
12. 不确定分类统一用 Expenses:Unknown，needsReview 设为 true。
13. 不确定付款账户时选择白名单中最合理的默认账户，needsReview 设为 true，并在 questions 中说明需要确认什么。
14. 没有日期时使用今天；相对日期按今天推算。
15. 账户分类只回答“钱本质上花/赚在哪里”，平台/人物/事件/渠道/用途放 metadata，不要为了淘宝、妈妈、母亲节等维度新造分类。
16. 每条交易必须输出 metadata（没有可判断信息时用 {}）和 tags（通常用 []）。metadata key 只用小写字母开头的英文，如 platform、channel、person、relationship、event、purpose、review；value 用字符串/数字/布尔值。
17. tag 只用于少量稳定专题，如 trip-2026-shanghai、moving、company-reimbursable；不要把 taobao、pdd、mom 这类高频维度做 tag。
18. 常见支出映射：餐饮/外卖/食堂/正餐→Expenses:Food:Meals；咖啡/奶茶/可乐/饮料/贩卖机→Expenses:Food:Drinks；生鲜/水果/零食/超市食品→Expenses:Food:Groceries；地铁/公交→Expenses:Transport:Public；打车/网约车→Expenses:Transport:Taxi；停车→Expenses:Transport:Parking；租车→Expenses:Transport:CarRental；房租→Expenses:Housing:Rent；水电燃气→Expenses:Housing:Utilities；物业/管理费→Expenses:Housing:Property；手机话费/流量→Expenses:Communication:Mobile；宽带/网络→Expenses:Communication:Internet；日用品/卫生用品/生活补给→Expenses:Shopping:Daily；衣服鞋包→Expenses:Shopping:Clothing；电子产品/电脑配件→Expenses:Shopping:Electronics；送礼购物→Expenses:Shopping:Gifts；无法判断商品性质的淘宝/PDD/京东→Expenses:Shopping:Other；发红包→Expenses:Social:RedPacket；礼金/随礼/探望礼→Expenses:Social:Gift；请客/应酬→Expenses:Social:Treat；软件/会员/订阅→Expenses:Digital:Subscription；医疗→Expenses:Health:Medical；药品→Expenses:Health:Pharmacy；娱乐→Expenses:Entertainment；旅行/酒店/门票→Expenses:Travel；手续费→Expenses:Fees。
19. 常见收入映射：工资→Income:Salary；奖金/绩效→Income:Bonus；利息按账户→Income:Interest:*；副业/临时项目→Income:SideProject；出租/租车收款→Income:Rental；报销/退款/返现→Income:Reimbursement；收红包→Income:Social:RedPacket；收礼金→Income:Social:Gift；无法判断→Income:Other 并 needsReview=true。`;
}

export async function parseNaturalLanguage(input: string, today: string) {
  const accounts = activeAccountNames();
  const provider = (process.env.LEDGER_AI_PROVIDER || "deepseek").toLowerCase();
  const parsed = provider === "deepseek" ? await parseWithDeepSeek(parserInstructions(today, accounts), input) : await parseWithOpenAI(parserInstructions(today, accounts), input);
  return normalizeAndValidateEntries(parsed, accounts);
}

export async function chatBookkeeping({ message, messages = [], draftEntries = [], today }: { message: string; messages?: BookkeepingChatMessage[]; draftEntries?: ParsedTransaction[]; today: string }): Promise<BookkeepingChatResult> {
  const accounts = activeAccountNames();
  draftEntries.forEach((entry, index) => validateEntry(entry, accounts, index));
  const system = `${parserInstructions(today, accounts)}

你现在是聊天式 AI 记账助理，需要支持多轮修改草稿。
输出根对象必须是：{"message":"给用户看的简短中文回复","entries":[...完整草稿...]}

聊天规则：
1. 如果用户输入新增流水，基于用户消息生成新的完整 entries。
2. 如果当前已有草稿，且用户说“第二条改成支付宝 / 删掉第一条 / 分类改购物 / 不是信用卡”等，必须在现有草稿上修改，并返回修改后的完整 entries。
3. 用户说删除某条时，从 entries 中移除对应条目；如果全部删除，返回空数组 entries: []。
4. 用户只是问你能做什么，且没有可生成/修改的流水时，entries 返回当前草稿，不要编造交易。
5. 不要写入账本；只维护草稿和预览。用户确认写入由系统按钮完成。
6. 如果用户是在问账本统计/消费/收入/明细，必须只根据“账本查询上下文”回答，不要编造；entries 必须返回空数组 []，不要保留或生成待确认预览。
7. message 要说明你做了什么，例如“已把第 2 条付款账户改为支付宝，请确认预览。”`;

  const conversation = messages.slice(-8).map((item) => `${item.role === "user" ? "用户" : "助理"}：${item.text}`).join("\n");
  const ledgerQueryContext = buildLedgerQueryContext(message, today);
  const queryOnly = ledgerQueryContext !== "";
  const input = `当前草稿 entries：
${JSON.stringify(draftEntries, null, 2)}

账本查询上下文（如果为空，说明这不是查询问题）：
${ledgerQueryContext || ""}

最近对话：
${conversation || "无"}

用户最新消息：
${message}`;

  const provider = (process.env.LEDGER_AI_PROVIDER || "deepseek").toLowerCase();
  const parsed = provider === "deepseek" ? await parseWithDeepSeek(system, input, { type: "json_object" }) : await parseWithOpenAI(system, input, { type: "json_schema", json_schema: { name: "beancount_chat_draft", strict: true, schema: bookkeepingChatJsonSchema } });
  const parsedObject = parsed as { message?: unknown; entries?: unknown };
  const entries = queryOnly ? [] : normalizeOptionalEntries({ entries: parsedObject.entries ?? [] }, accounts);
  return { message: typeof parsedObject.message === "string" && parsedObject.message.trim() ? parsedObject.message : queryOnly ? "已根据账本记录回答。" : `已更新 ${entries.length} 条预览。`, entries };
}

function createAgentRunner(apiKey: string, baseURL: string, model: string) {
  const provider = new OpenAIProvider({
    apiKey,
    baseURL: baseURL.replace(/\/$/, ""),
    useResponses: false,
  });

  return new Runner({
    modelProvider: provider,
    model,
    tracingDisabled: true,
    modelSettings: { temperature: 0 },
  });
}

function extractAgentText(finalOutput: unknown, providerName: string) {
  if (typeof finalOutput === "string" && finalOutput.trim()) return finalOutput;
  throw new Error(`${providerName} returned empty content`);
}

async function runParserAgent(options: {
  providerName: "OpenAI" | "DeepSeek";
  apiKey: string | undefined;
  baseURL: string;
  model: string;
  responseFormat: Record<string, unknown>;
  system: string;
  input: string;
}) {
  if (!options.apiKey) throw new Error(`${options.providerName === "OpenAI" ? "OPENAI" : "DEEPSEEK"}_API_KEY is not configured`);

  const runner = createAgentRunner(options.apiKey, options.baseURL, options.model);
  const agent = new Agent({
    name: "Beancount Parser",
    instructions: options.system,
    modelSettings: {
      temperature: 0,
      providerData: {
        response_format: options.responseFormat,
      },
    },
  });

  const result = await runner.run(agent, options.input, { maxTurns: 1 });
  return extractJson(extractAgentText(result.finalOutput, options.providerName));
}

async function parseWithOpenAI(system: string, input: string, responseFormat: Record<string, unknown> = {
  type: "json_schema",
  json_schema: {
    name: "parsed_beancount_transactions",
    strict: true,
    schema: parsedTransactionsJsonSchema,
  },
}) {
  return runParserAgent({
    providerName: "OpenAI",
    apiKey: process.env.OPENAI_API_KEY,
    baseURL: process.env.OPENAI_BASE_URL || "https://api.openai.com/v1",
    model: process.env.OPENAI_MODEL || "gpt-4.1-mini",
    responseFormat,
    system,
    input,
  });
}

async function parseWithDeepSeek(system: string, input: string, responseFormat: Record<string, unknown> = { type: "json_object" }) {
  return runParserAgent({
    providerName: "DeepSeek",
    apiKey: process.env.DEEPSEEK_API_KEY,
    baseURL: process.env.DEEPSEEK_BASE_URL || "https://api.deepseek.com",
    model: process.env.DEEPSEEK_MODEL || "deepseek-chat",
    responseFormat,
    system,
    input,
  });
}
