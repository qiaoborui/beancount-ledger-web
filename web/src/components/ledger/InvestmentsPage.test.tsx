import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { InvestmentsPage } from "./InvestmentsPage";
import type { InvestmentSummary } from "./types";

describe("InvestmentsPage", () => {
  it("ignores cached holdings without a real held security", () => {
    const investments: InvestmentSummary = {
      totalMarketValueCny: 0,
      updatedAt: "2026-06-12",
      positions: [],
      quotes: [],
      holdings: [
        {
          commodity: "VOO",
          commodityName: "Vanguard S&P 500 ETF",
          latestPrice: undefined,
          priceHistory: null,
          totalQuantity: 0,
          accountCount: 0,
          positions: null,
        },
        {
          commodity: "",
          commodityName: "",
          latestPrice: undefined,
          priceHistory: null,
          totalQuantity: 0,
          accountCount: 0,
          positions: null,
        },
      ],
    };

    expect(() => renderToString(<InvestmentsPage investments={investments} />)).not.toThrow();
    expect(renderToString(<InvestmentsPage investments={investments} />)).toContain("暂无证券商品");
  });
});
