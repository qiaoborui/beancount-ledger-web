import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { useLedgerDerivedData } from "./useLedgerDerivedData";
import type { AccountBalance, AccountView } from "../types";

function Probe({ accounts, balances = {}, accountBalances, page = "accounts", netWorthRows = [] }: { accounts: AccountView[]; balances?: Record<string, number>; accountBalances: AccountBalance[]; page?: string; netWorthRows?: { date: string; assets: number; liabilities: number; netWorth: number }[] }) {
  const data = useLedgerDerivedData({
    summary: null,
    accounts,
    balances,
    accountBalances,
    netWorthRows,
    page,
    valuationCurrency: "CNY",
  });
  return <pre>{JSON.stringify({ accountPageAccounts: data.accountPageAccounts, visibleBalances: data.visibleBalances, netWorthChart: data.netWorthChart })}</pre>;
}

function account(account: string, group: AccountView["group"] = "cash", currency = "CNY"): AccountView {
  return {
    account,
    openDate: "2026-01-01",
    closeDate: null,
    currency,
    alias: account,
    label: account,
    group,
    active: true,
  };
}

describe("useLedgerDerivedData", () => {
  it("shows security accounts that have valued balance rows", () => {
    const accounts: AccountView[] = [account("Assets:Broker:QQQ", "wealth", "QQQ")];
    const accountBalances: AccountBalance[] = [{
      account: "Assets:Broker:QQQ",
      currency: "QQQ",
      amount: 50,
      valuationCurrency: "CNY",
      valuation: 38500,
    }];

    const html = renderToString(<Probe accounts={accounts} accountBalances={accountBalances} />);

    expect(html).toContain("Assets:Broker:QQQ");
    expect(html).toContain("QQQ");
    expect(html).toContain("50");
  });

  it("hides account page accounts with no ledger activity or a zero balance", () => {
    const accounts: AccountView[] = [
      account("Assets:Cash"),
      account("Assets:Empty"),
      account("Assets:Zero"),
      account("Expenses:Food", "expense"),
    ];

    const html = renderToString(
      <Probe
        accounts={accounts}
        balances={{
          "Assets:Cash": 12000,
          "Assets:Zero": 0,
          "Expenses:Food": 8800,
        }}
        accountBalances={[
          { account: "Assets:Cash", currency: "CNY", amount: 12000, valuationCurrency: "CNY", valuation: 12000 },
          { account: "Assets:Zero", currency: "CNY", amount: 0, valuationCurrency: "CNY", valuation: 0 },
        ]}
      />,
    );

    expect(html).toContain("Assets:Cash");
    expect(html).not.toContain("Assets:Empty");
    expect(html).not.toContain("Assets:Zero");
    expect(html).toContain("Expenses:Food");
  });

  it("defers route-specific derived collections outside their pages", () => {
    const accounts: AccountView[] = [account("Assets:Cash")];

    const html = renderToString(
      <Probe
        page="transactions"
        accounts={accounts}
        balances={{ "Assets:Cash": 12000 }}
        accountBalances={[{ account: "Assets:Cash", currency: "CNY", amount: 12000, valuationCurrency: "CNY", valuation: 12000 }]}
        netWorthRows={[{ date: "2026-07-30", assets: 12000, liabilities: 2000, netWorth: 10000 }]}
      />,
    );

    expect(html).toContain("&quot;accountPageAccounts&quot;:[]");
    expect(html).toContain("&quot;visibleBalances&quot;:[]");
    expect(html).toContain("&quot;netWorthChart&quot;:[]");
    expect(html).not.toContain("Assets:Cash");
    expect(html).not.toContain("07-30");
  });

  it("prepares net worth chart rows on the net worth page", () => {
    const html = renderToString(
      <Probe
        page="net-worth"
        accounts={[]}
        accountBalances={[]}
        netWorthRows={[{ date: "2026-07-30", assets: 12000, liabilities: 2000, netWorth: 10000 }]}
      />,
    );

    expect(html).toContain("07-30");
    expect(html).toContain("120");
    expect(html).toContain("20");
    expect(html).toContain("100");
  });
});
