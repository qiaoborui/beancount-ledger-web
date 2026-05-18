export function FavaPage() {
  return (
    <section className="space-y-4">
      <div className="rounded-3xl border border-line bg-panel p-5 shadow-sm">
        <div className="text-xs uppercase tracking-[0.22em] text-stone">professional beancount dashboard</div>
        <div className="mt-2 flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="font-serif text-2xl font-medium text-ink">Fava 专业面板</h1>
            <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">
              这里通过已登录的主应用代理访问 Fava。请确保 Fava 只监听本机地址，例如 <code className="rounded bg-tag px-1 py-0.5">127.0.0.1:5000</code>，不要把 Fava 端口直接暴露到公网。
            </p>
          </div>
          <a
            href="/api/fava/"
            target="_blank"
            rel="noreferrer"
            className="rounded-xl border border-line bg-paper px-4 py-2 text-sm font-medium text-brand hover:bg-tag"
          >
            新窗口打开
          </a>
        </div>
      </div>

      <div className="overflow-hidden rounded-3xl border border-line bg-panel shadow-sm">
        <iframe
          title="Fava professional dashboard"
          src="/api/fava/"
          className="h-[calc(100dvh-15rem)] min-h-[680px] w-full bg-white"
        />
      </div>
    </section>
  );
}
