import { Eye, EyeOff } from "lucide-react";
import { Bar, BarChart, CartesianGrid, Legend, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { formatCny } from "@/lib/money";
import { HiddenPanel, Metric } from "./shared";
import type { PrivacySettings, Summary } from "./types";

export function HomePage({ summary, chart, privacySettings, onPrivacyChange }: { summary: Summary | null; chart: { day: string; 收入: number; 支出: number }[]; privacySettings: PrivacySettings; onPrivacyChange: <K extends keyof PrivacySettings>(key: K, value: PrivacySettings[K]) => void }) {
  return <>
    <section className="card overflow-hidden p-0">
      <div className="border-l-4 border-brand p-5 md:p-6">
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="text-xs uppercase tracking-[0.24em] text-stone">monthly summary</div>
            <h1 className="mt-2 font-serif text-3xl font-medium leading-tight md:text-4xl">本月现金流，先看方向。</h1>
            <p className="mt-3 max-w-2xl text-sm leading-6 text-olive">首页只放月度方向和最近流水；具体金额可在设置里选择默认显示或隐藏。</p>
          </div>
          <button className="shrink-0 rounded-xl border border-line bg-panel px-3 py-2 text-sm text-olive hover:bg-tag" onClick={() => onPrivacyChange("showHomeSummaryAmounts", !privacySettings.showHomeSummaryAmounts)} title={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"} aria-label={privacySettings.showHomeSummaryAmounts ? "隐藏首页金额" : "显示首页金额"}>
            {privacySettings.showHomeSummaryAmounts ? <EyeOff className="h-4 w-4 text-brand" /> : <Eye className="h-4 w-4 text-brand" />}
          </button>
        </div>
      </div>
      <div className="grid grid-cols-3 divide-x divide-line border-t border-line p-5 text-center">
        <Metric label="收入" value={privacySettings.showHomeSummaryAmounts ? formatCny((summary?.income ?? 0) / 100) : "••••••"} cls="amount-income text-lg sm:text-2xl" />
        <Metric label="支出" value={privacySettings.showHomeSummaryAmounts ? formatCny((summary?.expense ?? 0) / 100) : "••••••"} cls="amount-expense text-lg sm:text-2xl" />
        <Metric label="结余" value={privacySettings.showHomeSummaryAmounts ? formatCny((summary?.net ?? 0) / 100) : "••••••"} cls="amount-gold text-lg sm:text-2xl" />
      </div>
    </section>
    <section className="card mt-6 p-5">
      <div className="mb-4 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
        <div><h2 className="font-serif text-2xl font-medium">每日收支节奏</h2><p className="mt-1 text-sm text-olive">用低饱和颜色看波动，不让图表抢过结论。</p></div>
      </div>
      {privacySettings.showHomeCashflowChart ? <div className="h-72"><ResponsiveContainer width="100%" height="100%"><BarChart data={chart}><CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" /><XAxis dataKey="day" /><YAxis /><Tooltip /><Legend /><Bar dataKey="收入" fill="var(--chart-primary)" /><Bar dataKey="支出" fill="var(--chart-secondary)" /></BarChart></ResponsiveContainer></div> : <HiddenPanel text="每日收支图包含具体金额，默认隐藏。可到设置页改为默认显示。" />}
    </section>
  </>;
}
