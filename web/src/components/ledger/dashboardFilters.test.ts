import { describe, expect, it } from "vitest";
import type { TimeRange } from "@/lib/timeRange";
import { DEFAULT_DASHBOARD_FILTERS, dashboardFiltersToApiQuery, dashboardFiltersToSearchParams, hasActiveDashboardFilters, parseDashboardFiltersFromSearch } from "./dashboardFilters";

describe("dashboard filter query params", () => {
  it("parses comma and repeated array params into a stable filter state", () => {
    const filters = parseDashboardFiltersFromSearch("?type=income,expense&type=expense&category=Expenses%3AFood&category=Expenses%3ATransport%2CExpenses%3AFood&payee= Cafe &minAmount=10&maxAmount=20");

    expect(filters).toEqual({
      type: ["expense", "income"],
      category: ["Expenses:Food", "Expenses:Transport"],
      account: [],
      payee: ["Cafe"],
      tag: [],
      minAmount: "10",
      maxAmount: "20",
    });
  });

  it("serializes filters in fixed order while preserving unrelated params", () => {
    const params = dashboardFiltersToSearchParams({
      ...DEFAULT_DASHBOARD_FILTERS,
      category: ["Expenses:Transport", "Expenses:Food", "Expenses:Food"],
      type: ["income", "expense"],
      minAmount: " 10 ",
    }, new URLSearchParams("action=quick-entry&category=old&type=old"));

    expect(params.toString()).toBe("action=quick-entry&type=expense%2Cincome&category=Expenses%3AFood%2CExpenses%3ATransport&minAmount=10");
  });

  it("clears dashboard params without dropping non-dashboard query params", () => {
    const params = dashboardFiltersToSearchParams(DEFAULT_DASHBOARD_FILTERS, new URLSearchParams("category=Expenses%3AFood&action=ai-entry&tag=work"));

    expect(params.toString()).toBe("action=ai-entry");
  });

  it("keeps the dashboard API query shape used by the backend", () => {
    const timeRange: TimeRange = { start: "2026-05-01", end: "2026-06-01", preset: "custom" };
    const query = dashboardFiltersToApiQuery(timeRange, {
      ...DEFAULT_DASHBOARD_FILTERS,
      type: ["income", "expense"],
      category: ["Expenses:Food"],
      payee: ["Cafe"],
      tag: ["work"],
      minAmount: "10",
      maxAmount: "20",
    });

    expect(query).toBe("start=2026-05-01&end=2026-06-01&type=expense%2Cincome&category=Expenses%3AFood&payee=Cafe&tag=work&minAmount=10&maxAmount=20");
  });

  it("detects active filters after normalization", () => {
    expect(hasActiveDashboardFilters(DEFAULT_DASHBOARD_FILTERS)).toBe(false);
    expect(hasActiveDashboardFilters({ ...DEFAULT_DASHBOARD_FILTERS, maxAmount: " 100 " })).toBe(true);
  });
});
