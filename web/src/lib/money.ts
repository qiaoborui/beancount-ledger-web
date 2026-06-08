export function cents(amount: string | number): number {
  const n = typeof amount === "number" ? amount : Number(amount);
  return Math.round(n * 100);
}

export function fromCents(value: number): string {
  return (value / 100).toFixed(2);
}

const formatterCache = new Map<string, Intl.NumberFormat | null>();

function formatter(currency: string, compact = false) {
  const key = `${currency}:${compact ? "compact" : "standard"}`;
  const cached = formatterCache.get(key);
  if (cached) return cached;
  let next: Intl.NumberFormat | null = null;
  try {
    next = new Intl.NumberFormat(compact ? "en-US" : "zh-CN", {
      style: "currency",
      currency,
      ...(compact ? { notation: "compact", compactDisplay: "short", maximumFractionDigits: 1 } : { minimumFractionDigits: 2, maximumFractionDigits: 2 }),
    });
  } catch {
    next = null;
  }
  formatterCache.set(key, next);
  return next;
}

export function formatMoney(value: number, currency = "CNY"): string {
  const fmt = formatter(currency);
  return fmt ? fmt.format(value) : `${value.toFixed(2)} ${currency}`;
}

export function formatCompactMoney(value: number, currency = "CNY"): string {
  const fmt = formatter(currency, true);
  return fmt ? fmt.format(value) : `${compactNumber(value)} ${currency}`;
}

export function formatValuation(value: number, currency = "CNY"): string {
  return formatMoney(value, currency);
}

export function formatCompactValuation(value: number, currency = "CNY"): string {
  return formatCompactMoney(value, currency);
}

export function formatCny(value: number): string {
  return formatValuation(value, "CNY");
}

export function formatCompactCny(value: number): string {
  return formatCompactValuation(value, "CNY");
}

function compactNumber(value: number): string {
  return new Intl.NumberFormat("en-US", { notation: "compact", compactDisplay: "short", maximumFractionDigits: 1 }).format(value);
}

export function monthRange(month: string): { start: string; end: string } {
  const [year, m] = month.split("-").map(Number);
  const start = `${year}-${String(m).padStart(2, "0")}-01`;
  const endDate = m === 12 ? new Date(Date.UTC(year + 1, 0, 1)) : new Date(Date.UTC(year, m, 1));
  const end = `${endDate.getUTCFullYear()}-${String(endDate.getUTCMonth() + 1).padStart(2, "0")}-01`;
  return { start, end };
}

export function currentMonth(): string {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;
}
