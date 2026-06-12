import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { useLedgerDerivedData } from "./useLedgerDerivedData";
import type { AccountBalance, AccountView } from "../types";

function Probe({ accounts, accountBalances }: { accounts: AccountView[]; accountBalances: AccountBalance[] }) {
  const data = useLedgerDerivedData({
    summary: null,
    accounts,
    balances: {},
    accountBalances,
    netWorthRows: [],
    page: "accounts",
    valuationCurrency: "CNY",
  });
  return <pre>{JSON.stringify(data.visibleBalances)}</pre>;
}

describe("useLedgerDerivedData", () => {
  it("shows security accounts that have valued balance rows", () => {
    const accounts: AccountView[] = [{
      account: "Assets:Broker:QQQ",
      openDate: "2026-01-01",
      closeDate: null,
      currency: "QQQ",
      alias: "券商 QQQ",
      label: "券商 QQQ",
      group: "wealth",
      active: true,
    }];
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
});
