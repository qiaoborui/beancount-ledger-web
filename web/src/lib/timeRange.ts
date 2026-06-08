export type TimePreset = "week" | "month" | "quarter" | "year" | "all" | "custom";

export type TimeRange = {
  start: string; // YYYY-MM-DD
  end: string; // YYYY-MM-DD
  preset: TimePreset;
};

/** 当前月份字符串 "YYYY-MM" */
export function currentMonth(): string {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;
}

/** 获取某个日期所在周的周一（ISO 周，周一开始） */
export function getMonday(date: Date): Date {
  const d = new Date(date);
  const day = d.getDay();
  const diff = day === 0 ? -6 : 1 - day; // Sunday → go back 6, Mon-Sat → go to Monday
  d.setDate(d.getDate() + diff);
  d.setHours(0, 0, 0, 0);
  return d;
}

/** 周范围，以周一为起点，下周一为终点 */
export function weekRange(referenceDate?: string): { start: string; end: string } {
  const d = referenceDate ? new Date(referenceDate) : new Date();
  const monday = getMonday(d);
  const nextMonday = new Date(monday);
  nextMonday.setDate(nextMonday.getDate() + 7);
  const fmt = (dt: Date) => `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, "0")}-${String(dt.getDate()).padStart(2, "0")}`;
  return { start: fmt(monday), end: fmt(nextMonday) };
}

/** ISO 周序号（周一所在的年份 + 周数） */
export function weekLabel(referenceDate?: string): { year: number; week: number } {
  const d = referenceDate ? new Date(referenceDate) : new Date();
  const monday = getMonday(d);
  // ISO 周数：以该年第一个周四所在周为第 1 周
  const jan4 = new Date(monday.getFullYear(), 0, 4);
  const jan4Monday = getMonday(jan4);
  const diff = Math.round((monday.getTime() - jan4Monday.getTime()) / 86400000);
  const week = Math.floor(diff / 7) + 1;
  return { year: monday.getFullYear(), week };
}

/** 将月份字符串转为日期范围 { start: "YYYY-MM-01", end: "YYYY-MM+1-01" } */
export function monthRange(month: string): { start: string; end: string } {
  const [year, m] = month.split("-").map(Number);
  const start = `${year}-${String(m).padStart(2, "0")}-01`;
  const endDate = m === 12 ? new Date(Date.UTC(year + 1, 0, 1)) : new Date(Date.UTC(year, m, 1));
  const end = `${endDate.getUTCFullYear()}-${String(endDate.getUTCMonth() + 1).padStart(2, "0")}-01`;
  return { start, end };
}

/** 季度范围，1-3月=Q1, 4-6=Q2, 7-9=Q3, 10-12=Q4 */
export function quarterRange(year: number, quarter: number): { start: string; end: string } {
  const startMonth = (quarter - 1) * 3 + 1;
  const endMonth = startMonth + 3;
  const start = `${year}-${String(startMonth).padStart(2, "0")}-01`;
  let endYear = year;
  let endM = endMonth;
  if (endM > 12) {
    endYear = year + 1;
    endM = 1;
  }
  const end = `${endYear}-${String(endM).padStart(2, "0")}-01`;
  return { start, end };
}

/** 根据参考日期获取当前季度 */
function currentQuarter(referenceDate?: string): { year: number; quarter: number } {
  const d = referenceDate ? new Date(referenceDate) : new Date();
  const year = d.getFullYear();
  const month = d.getMonth() + 1;
  const quarter = Math.ceil(month / 3);
  return { year, quarter };
}

/** 构建时间范围 */
export function makeTimeRange(preset: TimePreset, referenceDate?: string): TimeRange {
  const ref = referenceDate ?? new Date().toISOString().slice(0, 10);
  const d = new Date(ref);
  const year = d.getFullYear();
  const month = d.getMonth() + 1;

  switch (preset) {
    case "week": {
      const { start, end } = weekRange(ref);
      return { start, end, preset };
    }
    case "month": {
      const { start, end } = monthRange(`${year}-${String(month).padStart(2, "0")}`);
      return { start, end, preset };
    }
    case "quarter": {
      const q = currentQuarter(ref);
      const { start, end } = quarterRange(q.year, q.quarter);
      return { start, end, preset };
    }
    case "year":
      return {
        start: `${year}-01-01`,
        end: `${year + 1}-01-01`,
        preset,
      };
    case "all":
      return {
        start: "2000-01-01",
        end: "2099-12-31",
        preset,
      };
    case "custom":
      // custom 由外部提供具体日期
      return { start: ref, end: ref, preset };
  }
}

/** 按时间范围粒度翻页 */
export function navigateTimeRange(range: TimeRange, delta: -1 | 1): TimeRange {
  if (range.preset === "all" || range.preset === "custom") return range;

  if (range.preset === "week") {
    const d = new Date(range.start);
    d.setDate(d.getDate() + delta * 7);
    return makeTimeRange("week", d.toISOString().slice(0, 10));
  }

  if (range.preset === "month") {
    const d = new Date(range.start);
    d.setMonth(d.getMonth() + delta);
    const y = d.getFullYear();
    const m = d.getMonth() + 1;
    return makeTimeRange("month", `${y}-${String(m).padStart(2, "0")}-01`);
  }

  if (range.preset === "quarter") {
    const d = new Date(range.start);
    d.setMonth(d.getMonth() + delta * 3);
    const y = d.getFullYear();
    const m = d.getMonth() + 1;
    return makeTimeRange("quarter", `${y}-${String(m).padStart(2, "0")}-01`);
  }

  if (range.preset === "year") {
    const d = new Date(range.start);
    d.setFullYear(d.getFullYear() + delta);
    return makeTimeRange("year", `${d.getFullYear()}-01-01`);
  }

  return range;
}

/** 转为 API 查询参数字符串 */
export function timeRangeToParams(range: TimeRange): string {
  return `start=${range.start}&end=${range.end}`;
}

/** 格式化时间范围标题 */
export function formatTimeRangeLabel(range: TimeRange): string {
  switch (range.preset) {
    case "week": {
      const s = range.start.slice(5).replace("-", "/").replace(/^0/, "");
      // end is exclusive (下一周一)，往前退一天得到周日
      const endDate = new Date(range.end);
      endDate.setDate(endDate.getDate() - 1);
      const e = `${endDate.getMonth() + 1}/${endDate.getDate()}`;
      return `${s} ~ ${e}`;
    }
    case "month":
      return range.start.slice(0, 7); // "2026-05"
    case "quarter": {
      const d = new Date(range.start);
      const y = d.getFullYear();
      const q = Math.ceil((d.getMonth() + 1) / 3);
      return `${y} Q${q}`;
    }
    case "year":
      return `${range.start.slice(0, 4)} 年`;
    case "all":
      return "全部时间";
    case "custom":
      return `${range.start} ~ ${range.end}`;
  }
}

/** 获取时间范围内的所有月份 */
export function getMonthsInRange(start: string, end: string): string[] {
  const months: string[] = [];
  const startDate = new Date(start);
  const endDate = new Date(end);
  const current = new Date(startDate.getFullYear(), startDate.getMonth(), 1);
  while (current < endDate) {
    months.push(`${current.getFullYear()}-${String(current.getMonth() + 1).padStart(2, "0")}`);
    current.setMonth(current.getMonth() + 1);
  }
  return months;
}

/** 解析 API 的 start/end 参数，支持 month 向后兼容 */
export function parseApiTimeParams(searchParams: URLSearchParams): { start: string; end: string } {
  let start = searchParams.get("start");
  let end = searchParams.get("end");
  const month = searchParams.get("month");

  if ((!start || !end) && month) {
    const range = monthRange(month);
    if (!start) start = range.start;
    if (!end) end = range.end;
  }

  if (!start) {
    const now = new Date();
    start = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-01`;
  }
  if (!end) {
    const [y, m] = start.split("-").map(Number);
    const d = new Date(y, m, 1);
    end = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-01`;
  }

  return { start, end };
}

/** 生成 localStorage 缓存键 */
export function timeRangeCacheKey(range: TimeRange, valuationCurrency = "CNY"): string {
  const suffix = `_valuation_${valuationCurrency}`;
  switch (range.preset) {
    case "week": {
      const { year, week } = weekLabel(range.start);
      return `ledger_cache_${year}-W${week}${suffix}`;
    }
    case "month":
      return `ledger_cache_${range.start.slice(0, 7)}${suffix}`;
    case "quarter": {
      const d = new Date(range.start);
      const y = d.getFullYear();
      const q = Math.ceil((d.getMonth() + 1) / 3);
      return `ledger_cache_${y}-Q${q}${suffix}`;
    }
    case "year":
      return `ledger_cache_${range.start.slice(0, 4)}${suffix}`;
    case "all":
      return `ledger_cache_all${suffix}`;
    case "custom":
      return `ledger_cache_${range.start}_${range.end}${suffix}`;
  }
}
