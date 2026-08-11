import { describe, expect, it } from "vitest";
import {
  canNavigateTimeRange,
  comparisonCacheIdentity,
  exclusiveEndDate,
  formatTimeRangeDateSpan,
  formatTimeRangePickerLabel,
  inclusiveEndDate,
  isCalendarMonthRange,
  isCurrentCalendarMonthRange,
  makeTimeRange,
  navigateTimeRange,
  timeRangeCacheKey,
} from "./timeRange";

describe("rolling time ranges", () => {
  it("builds an inclusive past 30 day window with an exclusive API end", () => {
    const range = makeTimeRange("last30", "2026-07-14");

    expect(range).toEqual({ start: "2026-06-15", end: "2026-07-15", preset: "last30" });
    expect(inclusiveEndDate(range)).toBe("2026-07-14");
    expect(formatTimeRangeDateSpan(range)).toBe("2026-06-15 至 2026-07-14");
  });

  it("moves rolling windows by their full duration", () => {
    const current = makeTimeRange("last30", "2026-07-14");
    const previous = navigateTimeRange(current, -1);

    expect(previous).toEqual({ start: "2026-05-16", end: "2026-06-15", preset: "last30" });
    expect(formatTimeRangePickerLabel(previous, "2026-07-14")).toBe("30 天范围");
    expect(canNavigateTimeRange(current, 1, "2026-07-14")).toBe(false);
    expect(canNavigateTimeRange(previous, 1, "2026-07-14")).toBe(true);
  });

  it("uses calendar dates for the past twelve months", () => {
    const range = makeTimeRange("last12months", "2026-07-14");
    expect(range).toEqual({
      start: "2025-07-15",
      end: "2026-07-15",
      preset: "last12months",
    });
    expect(navigateTimeRange(range, -1)).toEqual({
      start: "2024-07-15",
      end: "2025-07-15",
      preset: "last12months",
    });
    expect(formatTimeRangePickerLabel(navigateTimeRange(range, -1), "2026-07-14")).toBe("12 个月范围");
    expect(makeTimeRange("last12months", "2024-02-29")).toEqual({
      start: "2023-03-01",
      end: "2024-03-01",
      preset: "last12months",
    });
  });

  it("converts custom inclusive end dates to the API boundary", () => {
    expect(exclusiveEndDate("2026-07-14")).toBe("2026-07-15");
  });

  it("keeps rolling cache entries scoped to their exact dates", () => {
    const range = makeTimeRange("last7", "2026-07-14");
    expect(timeRangeCacheKey(range)).toContain("last7_2026-07-08_2026-07-15");
  });

  it("recognizes exact calendar months independently of the selected preset", () => {
    expect(isCalendarMonthRange({ start: "2026-08-01", end: "2026-09-01" })).toBe(true);
    expect(isCalendarMonthRange({ start: "2026-08-02", end: "2026-09-02" })).toBe(false);
    expect(isCurrentCalendarMonthRange({ start: "2026-08-01", end: "2026-09-01" }, "2026-08-12")).toBe(true);
    expect(isCurrentCalendarMonthRange({ start: "2026-08-01", end: "2026-09-01" }, "2026-09-01")).toBe(false);
  });

  it("uses one cache identity across future, current, completed, and unknown month states", () => {
    const september = { start: "2026-09-01", end: "2026-10-01" };
    expect(comparisonCacheIdentity(september, "2026-08-11")).toBe("future");
    expect(comparisonCacheIdentity(september, "2026-09-01")).toBe("2026-09-01");
    expect(comparisonCacheIdentity(september, "2026-10-01")).toBe("complete");
    expect(comparisonCacheIdentity(september)).toBe("unknown");
    expect(comparisonCacheIdentity(september, "not-a-date")).toBe("unknown");
  });
});
