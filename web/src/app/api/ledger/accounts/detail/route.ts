import { NextResponse } from "next/server";
import { requireSensitiveUnlockJson } from "@/lib/apiAuth";
import { accountDetail } from "@/lib/beancountParser";
import { getLedgerSnapshot } from "@/lib/ledgerCache";

export async function GET(request: Request) {
  const authError = await requireSensitiveUnlockJson();
  if (authError) return authError;

  const { searchParams } = new URL(request.url);
  const account = searchParams.get("account");
  if (!account) {
    return NextResponse.json({ error: "缺少 account 参数" }, { status: 400 });
  }

  const snapshot = getLedgerSnapshot();
  const acct = snapshot.accounts.find((a) => a.account === account);
  if (!acct) {
    return NextResponse.json({ error: `账户不存在: ${account}` }, { status: 404 });
  }

  const rows = accountDetail(account, snapshot.transactions);
  const currentBalance = snapshot.balances[account] ?? 0;

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
