import type { PrivacySettings } from "./types";
import type { WebPushState } from "./hooks/useWebPush";

export function SettingsPage({ settings, onChange, webPush, onEnableWebPush, onDisableWebPush, onTestWebPush }: { settings: PrivacySettings; onChange: <K extends keyof PrivacySettings>(key: K, value: PrivacySettings[K]) => void; webPush: WebPushState; onEnableWebPush: () => void; onDisableWebPush: () => void; onTestWebPush: () => void }) {
  return <div className="space-y-6">
    <section className="card p-5 md:p-6">
      <div className="border-l-4 border-brand pl-4">
        <div className="text-xs uppercase tracking-[0.24em] text-stone">privacy defaults</div>
        <h1 className="mt-2 font-serif text-3xl font-medium">默认显示设置</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">控制打开账本时哪些金额默认可见。设置只保存在当前浏览器，不写入 Beancount 文件。</p>
      </div>
      <div className="mt-6 divide-y divide-line rounded-2xl border border-line bg-panel">
        <SettingToggle title="首页月度收入 / 支出 / 结余" description="关闭后首页三个指标默认显示为 ••••••。" checked={settings.showHomeSummaryAmounts} onChange={(checked) => onChange("showHomeSummaryAmounts", checked)} />
        <SettingToggle title="首页每日收支图" description="关闭后隐藏每日柱状图，避免图表 tooltip 暴露具体金额。" checked={settings.showHomeCashflowChart} onChange={(checked) => onChange("showHomeCashflowChart", checked)} />
        <SettingToggle title="账户页余额" description="控制进入账户页时是否默认展开全部账户余额；仍可在页面内临时切换。" checked={settings.showAccountBalancesByDefault} onChange={(checked) => onChange("showAccountBalancesByDefault", checked)} />
        <SettingToggle title="净资产页金额与曲线" description="控制进入净资产页时是否默认显示资产、负债、净资产和曲线。" checked={settings.showNetWorthByDefault} onChange={(checked) => onChange("showNetWorthByDefault", checked)} />
        <SettingToggle title="损益表金额" description="控制进入损益表时是否默认显示各分类的具体金额。" checked={settings.showIncomeStatementByDefault} onChange={(checked) => onChange("showIncomeStatementByDefault", checked)} />
      </div>
    </section>

    <section className="card p-5 md:p-6">
      <div className="border-l-4 border-brand pl-4">
        <div className="text-xs uppercase tracking-[0.24em] text-stone">web push</div>
        <h2 className="mt-2 font-serif text-3xl font-medium">浏览器推送通知</h2>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">开启后，这台设备可以接收账本后台任务、AI 任务或预算提醒推送。Safari 需要把网页添加到 Dock/主屏幕后才支持 Web Push。</p>
      </div>
      <div className="mt-6 rounded-2xl border border-line bg-panel p-4">
        <div className="grid gap-3 text-sm text-olive sm:grid-cols-2">
          <StatusLine label="浏览器支持" value={webPush.supported ? "支持" : "不支持"} />
          <StatusLine label="通知权限" value={webPush.permission} />
          <StatusLine label="服务端配置" value={webPush.configured ? "已配置" : "未配置 VAPID"} />
          <StatusLine label="当前设备" value={webPush.subscribed ? "已订阅" : "未订阅"} />
        </div>
        {webPush.error && <div className="mt-4 rounded-xl border border-line bg-tag px-3 py-2 text-sm text-warm">{webPush.error}</div>}
        <div className="mt-4 flex flex-wrap gap-3">
          {!webPush.subscribed ? <button className="rounded-xl bg-brand px-4 py-2 text-paper disabled:opacity-60" onClick={onEnableWebPush} disabled={webPush.loading || !webPush.supported || !webPush.configured}>开启 Web Push</button> : <button className="rounded-xl border border-line bg-paper px-4 py-2 text-warm disabled:opacity-60" onClick={onDisableWebPush} disabled={webPush.loading}>关闭 Web Push</button>}
          <button className="rounded-xl border border-line bg-paper px-4 py-2 text-brand disabled:opacity-60" onClick={onTestWebPush} disabled={webPush.loading || !webPush.subscribed || !webPush.configured}>发送测试通知</button>
        </div>
      </div>
    </section>
  </div>;
}

function StatusLine({ label, value }: { label: string; value: string }) {
  return <div className="flex items-center justify-between gap-3 rounded-xl bg-paper px-3 py-2"><span className="text-stone">{label}</span><span className="font-medium text-warm">{value}</span></div>;
}

function SettingToggle({ title, description, checked, onChange }: { title: string; description: string; checked: boolean; onChange: (checked: boolean) => void }) {
  return <label className="flex cursor-pointer items-center justify-between gap-4 p-4">
    <span className="min-w-0">
      <span className="block font-medium text-ink">{title}</span>
      <span className="mt-1 block text-sm leading-6 text-olive">{description}</span>
    </span>
    <input className="h-5 w-5 shrink-0 accent-brand" type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} />
  </label>;
}
