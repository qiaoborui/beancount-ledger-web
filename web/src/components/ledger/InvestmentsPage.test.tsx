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

  it("renders original-currency market value with cents", () => {
    const investments: InvestmentSummary = {
      totalMarketValueCny: 429915,
      updatedAt: "2026-06-15",
      positions: [
        {
          account: "Assets:HK:ZABank:Investments:NVDA",
          accountLabel: "众安银行 NVDA 持仓",
          commodity: "NVDA",
          commodityName: "NVIDIA Corporation",
          quantity: 3,
          latestPrice: { date: "2026-06-15", commodity: "NVDA", amount: 211.99, currency: "USD" },
          averageCost: 209.5,
          costValue: 628.5,
          costCurrency: "USD",
          marketValue: 635.97,
          marketCurrency: "USD",
          marketValueCny: 429915,
        },
      ],
      quotes: [],
      holdings: [
        {
          commodity: "NVDA",
          commodityName: "NVIDIA Corporation",
          latestPrice: { date: "2026-06-15", commodity: "NVDA", amount: 211.99, currency: "USD" },
          priceHistory: [
            { date: "2026-06-12", commodity: "NVDA", amount: 205.19, currency: "USD" },
            { date: "2026-06-15", commodity: "NVDA", amount: 211.99, currency: "USD" },
          ],
          totalQuantity: 3,
          averageCost: 209.5,
          totalCostValue: 628.5,
          costCurrency: "USD",
          totalMarketValue: 635.97,
          marketCurrency: "USD",
          totalMarketValueCny: 429915,
          accountCount: 1,
          positions: [
            {
              account: "Assets:HK:ZABank:Investments:NVDA",
              accountLabel: "众安银行 NVDA 持仓",
              commodity: "NVDA",
              commodityName: "NVIDIA Corporation",
              quantity: 3,
              latestPrice: { date: "2026-06-15", commodity: "NVDA", amount: 211.99, currency: "USD" },
              averageCost: 209.5,
              costValue: 628.5,
              costCurrency: "USD",
              marketValue: 635.97,
              marketCurrency: "USD",
              marketValueCny: 429915,
            },
          ],
        },
      ],
    };

    const html = renderToString(<InvestmentsPage investments={investments} />);

    expect(html).toContain("US$635.97");
    expect(html).toContain("成本价");
    expect(html).toContain("原币成本");
    expect(html).toContain("US$209.50");
    expect(html).toContain("US$628.50");
    expect(html).not.toContain("$636");
  });
});
