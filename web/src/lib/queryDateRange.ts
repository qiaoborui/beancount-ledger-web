const queryMinDate = "2000-01-01";
const queryMaxDate = "2100-01-01";

type QueryDateRange = {
  start: string;
  end: string;
};

const dateTermPattern = /(?:^|[\s(])date(>=|<=|>|<|=|:)(\d{4}-\d{2}(?:-\d{2})?)(?=$|[\s)])/gi;

export function queryDateRange(query: string): QueryDateRange | null {
  const raw = query.trim();
  if (!raw || /\b(?:OR|NOT)\b/i.test(raw)) return null;

  let range: QueryDateRange | null = null;
  for (const match of raw.matchAll(dateTermPattern)) {
    const termRange = queryDateTermRange(match[1], match[2]);
    if (!termRange) return null;
    range = range ? intersectDateRanges(range, termRange) : termRange;
    if (!range) return null;
  }
  return range;
}

function queryDateTermRange(op: string, value: string): QueryDateRange | null {
  if (op === ":" || op === "=") return exactDateRange(value);
  const date = parseDay(value);
  if (!date) return null;
  if (op === ">=") return { start: date, end: queryMaxDate };
  if (op === ">") return { start: addDays(date, 1), end: queryMaxDate };
  if (op === "<") return { start: queryMinDate, end: date };
  if (op === "<=") return { start: queryMinDate, end: addDays(date, 1) };
  return null;
}

function exactDateRange(value: string): QueryDateRange | null {
  if (/^\d{4}-\d{2}$/.test(value)) {
    const monthStart = parseMonth(value);
    if (!monthStart) return null;
    return { start: monthStart, end: addMonths(monthStart, 1) };
  }
  const date = parseDay(value);
  if (!date) return null;
  return { start: date, end: addDays(date, 1) };
}

function intersectDateRanges(left: QueryDateRange, right: QueryDateRange): QueryDateRange | null {
  const start = left.start > right.start ? left.start : right.start;
  const end = left.end < right.end ? left.end : right.end;
  if (start >= end) return null;
  return { start, end };
}

function parseDay(value: string): string | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const date = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(date.getTime())) return null;
  const formatted = formatDate(date);
  return formatted === value ? formatted : null;
}

function parseMonth(value: string): string | null {
  if (!/^\d{4}-\d{2}$/.test(value)) return null;
  const date = new Date(`${value}-01T00:00:00Z`);
  if (Number.isNaN(date.getTime())) return null;
  return formatDate(date).startsWith(`${value}-`) ? formatDate(date) : null;
}

function addDays(value: string, days: number): string {
  const date = new Date(`${value}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return formatDate(date);
}

function addMonths(value: string, months: number): string {
  const date = new Date(`${value}T00:00:00Z`);
  date.setUTCMonth(date.getUTCMonth() + months);
  return formatDate(date);
}

function formatDate(date: Date): string {
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")}`;
}
