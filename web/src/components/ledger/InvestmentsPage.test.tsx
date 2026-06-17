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
      lots: [],
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
          lots: null,
        },
        {
          commodity: "",
          commodityName: "",
          latestPrice: undefined,
          priceHistory: null,
          totalQuantity: 0,
          accountCount: 0,
          positions: null,
          lots: null,
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
          lots: [
            {
              date: "2026-06-16",
              account: "Assets:HK:ZABank:Investments:NVDA",
              accountLabel: "众安银行 NVDA 持仓",
              commodity: "NVDA",
              commodityName: "NVIDIA Corporation",
              quantity: 3,
              unitCost: 209.5,
              costValue: 628.5,
              costCurrency: "USD",
            },
          ],
        },
      ],
      lots: [
        {
          date: "2026-06-16",
          account: "Assets:HK:ZABank:Investments:NVDA",
          accountLabel: "众安银行 NVDA 持仓",
          commodity: "NVDA",
          commodityName: "NVIDIA Corporation",
          quantity: 3,
          unitCost: 209.5,
          costValue: 628.5,
          costCurrency: "USD",
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
              lots: [
                {
                  date: "2026-06-16",
                  account: "Assets:HK:ZABank:Investments:NVDA",
                  accountLabel: "众安银行 NVDA 持仓",
                  commodity: "NVDA",
                  commodityName: "NVIDIA Corporation",
                  quantity: 3,
                  unitCost: 209.5,
                  costValue: 628.5,
                  costCurrency: "USD",
                },
              ],
            },
          ],
          lots: [
            {
              date: "2026-06-16",
              account: "Assets:HK:ZABank:Investments:NVDA",
              accountLabel: "众安银行 NVDA 持仓",
              commodity: "NVDA",
              commodityName: "NVIDIA Corporation",
              quantity: 3,
              unitCost: 209.5,
              costValue: 628.5,
              costCurrency: "USD",
            },
          ],
        },
      ],
    };

    const html = renderToString(<InvestmentsPage investments={investments} />);

    expect(html).toContain("US$635.97");
    expect(html).toContain("买入批次");
    expect(html).toContain("2026-06-16");
    expect(html).toContain("持有股数");
    expect(html).toContain("平均成本");
    expect(html).toContain("总成本");
    expect(html).toContain("US$209.50");
    expect(html).toContain("US$628.50");
    expect(html).toContain("3");
    expect(html).not.toContain("$636");
  });
});
