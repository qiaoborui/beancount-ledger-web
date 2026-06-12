export function cents(amount: string | number): number {
  const n = typeof amount === "number" ? amount : Number(amount);
  return Math.round(n * 100);
}

export function fromCents(value: number): string {
  return (value / 100).toFixed(2);
}

const cnyFormatter = new Intl.NumberFormat("zh-CN", {
  style: "currency",
  currency: "CNY",
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

const compactCnyFormatter = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "CNY",
  notation: "compact",
  compactDisplay: "short",
  maximumFractionDigits: 1,
});

export function formatCny(value: number): string {
  return cnyFormatter.format(value);
}

export function formatCompactCny(value: number): string {
  return compactCnyFormatter.format(value);
}

export function formatMoney(value: number, currency: string): string {
  try {
    return new Intl.NumberFormat("zh-CN", {
      style: "currency",
      currency,
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }).format(value);
  } catch {
    return `${value.toFixed(2)} ${currency}`;
  }
}

export function formatCompactMoney(value: number, currency: string): string {
  try {
    return new Intl.NumberFormat("en-US", {
      style: "currency",
      currency,
      notation: "compact",
      compactDisplay: "short",
      maximumFractionDigits: 1,
    }).format(value);
  } catch {
    return `${new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 }).format(value)} ${currency}`;
  }
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
