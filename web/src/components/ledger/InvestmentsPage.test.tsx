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
        {
          account: "Assets:Broker:QQQ",
          accountLabel: "券商 QQQ 持仓",
          commodity: "QQQ",
          commodityName: "Invesco QQQ Trust",
          quantity: 0.0056,
          latestPrice: { date: "2026-06-15", commodity: "QQQ", amount: 729.86, currency: "USD" },
          marketValue: 4.087216,
          marketCurrency: "USD",
          marketValueCny: 2759,
          lots: [
            {
              date: "2026-06-12",
              account: "Assets:Broker:QQQ",
              accountLabel: "券商 QQQ 持仓",
              commodity: "QQQ",
              commodityName: "Invesco QQQ Trust",
              quantity: 0.0056,
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
        {
          date: "2026-06-12",
          account: "Assets:Broker:QQQ",
          accountLabel: "券商 QQQ 持仓",
          commodity: "QQQ",
          commodityName: "Invesco QQQ Trust",
          quantity: 0.0056,
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
        {
          commodity: "QQQ",
          commodityName: "Invesco QQQ Trust",
          latestPrice: { date: "2026-06-15", commodity: "QQQ", amount: 729.86, currency: "USD" },
          priceHistory: [
            { date: "2026-06-12", commodity: "QQQ", amount: 725.2, currency: "USD" },
            { date: "2026-06-15", commodity: "QQQ", amount: 729.86, currency: "USD" },
          ],
          totalQuantity: 0.0056,
          totalMarketValue: 4.087216,
          marketCurrency: "USD",
          totalMarketValueCny: 2759,
          accountCount: 1,
          positions: [
            {
              account: "Assets:Broker:QQQ",
              accountLabel: "券商 QQQ 持仓",
              commodity: "QQQ",
              commodityName: "Invesco QQQ Trust",
              quantity: 0.0056,
              latestPrice: { date: "2026-06-15", commodity: "QQQ", amount: 729.86, currency: "USD" },
              marketValue: 4.087216,
              marketCurrency: "USD",
              marketValueCny: 2759,
              lots: [
                {
                  date: "2026-06-12",
                  account: "Assets:Broker:QQQ",
                  accountLabel: "券商 QQQ 持仓",
                  commodity: "QQQ",
                  commodityName: "Invesco QQQ Trust",
                  quantity: 0.0056,
                },
              ],
            },
          ],
          lots: [
            {
              date: "2026-06-12",
              account: "Assets:Broker:QQQ",
              accountLabel: "券商 QQQ 持仓",
              commodity: "QQQ",
              commodityName: "Invesco QQQ Trust",
              quantity: 0.0056,
            },
          ],
        },
      ],
    };

    const html = renderToString(<InvestmentsPage investments={investments} />);

    expect(html).toContain("US$635.97");
    expect(html).toContain("买入批次");
    expect(html).toContain("2026-06-16");
    expect(html).toContain("1/2 有成本");
    expect(html).toContain("2 笔买入");
    expect(html).toContain("持有股数");
    expect(html).toContain("平均成本");
    expect(html).toContain("总成本");
    expect(html).toContain("US$209.50");
    expect(html).toContain("US$628.50");
    expect(html).toContain("QQQ");
    expect(html).toContain("3");
    expect(html).not.toContain("买入日期");
    expect(html).not.toContain("账户拆分");
    expect(html).not.toContain("$636");
  });

  it("renders CNY security unit prices without dropping decimal precision", () => {
    const investments: InvestmentSummary = {
      totalMarketValueCny: 214800,
      updatedAt: "2026-06-30",
      positions: [
        {
          account: "Assets:CN:CMB:Securities:SZ159350",
          accountLabel: "招商证券深证50 ETF 富国 (159350)",
          commodity: "SZ159350",
          commodityName: "Fullgoal Shenzhen 50 Index ETF (159350)",
          quantity: 1200,
          latestPrice: { date: "2026-06-30", commodity: "SZ159350", amount: 1.79, currency: "CNY" },
          averageCost: 1.7702,
          costValue: 2124.24,
          costCurrency: "CNY",
          costValueCny: 212424,
          marketValue: 2148,
          marketCurrency: "CNY",
          marketValueCny: 214800,
          lots: [],
        },
      ],
      lots: [],
      quotes: [],
      holdings: [
        {
          commodity: "SZ159350",
          commodityName: "Fullgoal Shenzhen 50 Index ETF (159350)",
          latestPrice: { date: "2026-06-30", commodity: "SZ159350", amount: 1.79, currency: "CNY" },
          priceHistory: [],
          totalQuantity: 1200,
          averageCost: 1.7702,
          totalCostValue: 2124.24,
          costCurrency: "CNY",
          totalCostValueCny: 212424,
          totalMarketValue: 2148,
          marketCurrency: "CNY",
          totalMarketValueCny: 214800,
          accountCount: 1,
          positions: [],
          lots: [],
        },
      ],
    };

    const html = renderToString(<InvestmentsPage investments={investments} />);

    expect(html).toContain("¥1.7702");
    expect(html).toContain("¥2,124.24");
    expect(html).toContain("+¥23.76");
    expect(html).toContain("折算成本");
  });

});
