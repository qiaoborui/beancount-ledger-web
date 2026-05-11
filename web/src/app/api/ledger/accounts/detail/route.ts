import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { accountDetail, parseAccounts, currentBalances, parseTransactions } from "@/lib/beancountParser";

export async function GET(request: Request) {
  await requireAuth();

  const { searchParams } = new URL(request.url);
  const account = searchParams.get("account");
  if (!account) {
    return NextResponse.json({ error: "缺少 account 参数" }, { status: 400 });
  }

  const accounts = parseAccounts();
  const acct = accounts.find((a) => a.account === account);
  if (!acct) {
    return NextResponse.json({ error: `账户不存在: ${account}` }, { status: 404 });
  }

  const txns = parseTransactions();
  const rows = accountDetail(account, txns);
  const balances = currentBalances(txns);
  const currentBalance = balances[account] ?? 0;

  return NextResponse.json({
    account: acct.account,
    label: acct.label,
    alias: acct.alias,
    group: acct.group,
    active: acct.active,
    currency: acct.currency,
    currentBalance,
    rows,
  });
}
