import { useEffect, useMemo, useState, type FormEvent, type ReactNode } from "react";
import { Bot, Check, Database, Github, KeyRound, LoaderCircle, ShieldCheck } from "lucide-react";
import { fetchJson } from "@/lib/clientFetch";

type SetupForm = {
  installCode: string;
  adminPassword: string;
  confirmPassword: string;
  githubOwner: string;
  githubRepo: string;
  githubBranch: string;
  githubApiUrl: string;
  githubWriteToken: string;
  githubIndexToken: string;
  aiProvider: string;
  aiBaseUrl: string;
  aiModel: string;
  aiApiKey: string;
  indexerIntervalSeconds: number;
  indexerRetryInitialSeconds: number;
  indexerRetryMaximumSeconds: number;
};

const initialForm: SetupForm = {
  installCode: "",
  adminPassword: "",
  confirmPassword: "",
  githubOwner: "",
  githubRepo: "",
  githubBranch: "main",
  githubApiUrl: "",
  githubWriteToken: "",
  githubIndexToken: "",
  aiProvider: "openai-compatible",
  aiBaseUrl: "https://api.deepseek.com",
  aiModel: "deepseek-chat",
  aiApiKey: "",
  indexerIntervalSeconds: 60,
  indexerRetryInitialSeconds: 5,
  indexerRetryMaximumSeconds: 60,
};

const fieldClass = "mt-2 h-11 w-full rounded-md border border-line bg-paper px-3 text-sm text-ink outline-none placeholder:text-stone focus-visible:ring-2 focus-visible:ring-brand/25";

export function InstanceSetupPage({ onComplete }: { onComplete: () => void }) {
  const [form, setForm] = useState(initialForm);
  const [submitting, setSubmitting] = useState(false);
  const [submitStage, setSubmitStage] = useState<"idle" | "testing" | "saving">("idle");
  const [error, setError] = useState("");
  const passwordError = useMemo(() => {
    if (!form.adminPassword) return "";
    if (form.adminPassword.length < 12) return "管理员密码至少需要 12 个字符";
    if (form.confirmPassword && form.confirmPassword !== form.adminPassword) return "两次输入的密码不一致";
    return "";
  }, [form.adminPassword, form.confirmPassword]);

  useEffect(() => {
    document.body.classList.add("instance-setup-active");
    return () => document.body.classList.remove("instance-setup-active");
  }, []);

  function update<K extends keyof SetupForm>(key: K, value: SetupForm[K]) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    setError("");
    if (passwordError || form.confirmPassword !== form.adminPassword) {
      setError(passwordError || "请确认管理员密码");
      return;
    }
    setSubmitting(true);
    try {
      const { confirmPassword: _confirmPassword, ...payload } = form;
      setSubmitStage("testing");
      await fetchJson("/api/setup/test", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      }, undefined, { kind: "write" });
      setSubmitStage("saving");
      await fetchJson("/api/setup/install", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      }, undefined, { kind: "write" });
      onComplete();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "安装失败，请检查配置后重试");
    } finally {
      setSubmitting(false);
      setSubmitStage("idle");
    }
  }

  return <main className="h-dvh min-h-0 overflow-hidden bg-paper text-ink">
    <div className="mx-auto grid h-full max-w-7xl lg:grid-cols-[minmax(280px,0.72fr)_minmax(0,1.28fr)]">
      <aside className="hidden border-r border-line bg-panel px-10 py-12 lg:flex lg:flex-col">
        <div className="flex items-center gap-3">
          <span className="grid h-10 w-10 place-items-center rounded-md bg-brand text-paper"><Database className="h-5 w-5" /></span>
          <div><p className="text-sm font-semibold">Beancount Ledger Web</p><p className="text-xs text-stone">实例安装</p></div>
        </div>
        <div className="my-auto max-w-sm">
          <p className="text-xs font-medium tracking-[0.16em] text-brand">YOUR INSTANCE</p>
          <h1 className="mt-4 text-balance text-3xl font-semibold leading-tight tracking-[-0.022em]">把运行配置留在你自己的数据库里</h1>
          <p className="mt-4 text-pretty text-sm leading-6 text-stone">部署环境只负责连接数据库和保护加密根密钥。账本仓库、管理员密码、AI 与 indexer 配置由当前实例自行管理。</p>
          <ol className="mt-8 space-y-4 text-sm">
            {[
              ["验证实例", "输入容器日志中的一次性安装码"],
              ["连接账本", "为 API 写入和 indexer 读取使用不同 Token"],
              ["启用 Agent", "配置 OpenAI 兼容的模型服务"],
            ].map(([title, detail], index) => <li key={title} className="flex gap-3">
              <span className="grid h-6 w-6 shrink-0 place-items-center rounded-full bg-tag text-xs font-medium text-brand">{index + 1}</span>
              <span><span className="block font-medium">{title}</span><span className="mt-0.5 block text-xs leading-5 text-stone">{detail}</span></span>
            </li>)}
          </ol>
        </div>
        <p className="flex items-center gap-2 text-xs text-stone"><ShieldCheck className="h-4 w-4 text-brand" />秘密经加密后写入 Postgres，API 不会回显明文</p>
      </aside>

      <section className="flex h-full min-h-0 flex-col overflow-hidden">
        <header className="shrink-0 border-b border-line bg-paper px-5 py-4 sm:px-8 lg:px-10">
          <div className="mx-auto flex max-w-3xl items-center justify-between gap-4">
            <div><p className="text-sm font-semibold">完成实例安装</p><p className="mt-1 text-xs text-stone">保存后使用管理员密码登录，再由建账 Agent 创建第一个账本。</p></div>
            <span className="hidden rounded-full bg-tag px-3 py-1 text-xs text-brand sm:inline-flex">数据库配置</span>
          </div>
        </header>

        <form onSubmit={submit} className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-5 py-6 sm:px-8 lg:px-10">
          <div className="mx-auto max-w-3xl space-y-10 pb-[calc(2rem+env(safe-area-inset-bottom))]">
            <SetupSection icon={<KeyRound className="h-4 w-4" />} title="验证实例" description="安装码只会在首次启动时打印到 server 容器日志。">
              <Field label="一次性安装码"><input required autoComplete="one-time-code" value={form.installCode} onChange={(event) => update("installCode", event.target.value.toUpperCase())} placeholder="XXXXXX-XXXXXX-XXXXXX-XXXXXX" className={`${fieldClass} font-mono uppercase tracking-wide`} /></Field>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="管理员密码" error={passwordError}><input required minLength={12} type="password" autoComplete="new-password" value={form.adminPassword} onChange={(event) => update("adminPassword", event.target.value)} className={fieldClass} /></Field>
                <Field label="确认密码"><input required type="password" autoComplete="new-password" value={form.confirmPassword} onChange={(event) => update("confirmPassword", event.target.value)} className={fieldClass} /></Field>
              </div>
            </SetupSection>

            <SetupSection icon={<Github className="h-4 w-4" />} title="连接私有账本仓库" description="Server 只持有 Contents 读写 Token，indexer 只领取独立的只读 Token。">
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="GitHub 用户或组织"><input required value={form.githubOwner} onChange={(event) => update("githubOwner", event.target.value)} placeholder="your-name" className={fieldClass} /></Field>
                <Field label="私有仓库"><input required value={form.githubRepo} onChange={(event) => update("githubRepo", event.target.value)} placeholder="my-ledger" className={fieldClass} /></Field>
              </div>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="分支"><input required value={form.githubBranch} onChange={(event) => update("githubBranch", event.target.value)} className={fieldClass} /></Field>
                <Field label="GitHub API 地址" hint="github.com 用户留空"><input type="url" value={form.githubApiUrl} onChange={(event) => update("githubApiUrl", event.target.value)} placeholder="https://github.example/api/v3" className={fieldClass} /></Field>
              </div>
              <Field label="Server 写入 Token" hint="Fine-grained token，Contents: Read and write"><input required type="password" autoComplete="off" value={form.githubWriteToken} onChange={(event) => update("githubWriteToken", event.target.value)} className={fieldClass} /></Field>
              <Field label="Indexer 只读 Token" hint="使用另一个 Fine-grained token，Contents: Read-only"><input required type="password" autoComplete="off" value={form.githubIndexToken} onChange={(event) => update("githubIndexToken", event.target.value)} className={fieldClass} /></Field>
            </SetupSection>

            <SetupSection icon={<Bot className="h-4 w-4" />} title="配置账本 Agent" description="支持 DeepSeek、OpenAI 与其他 OpenAI 兼容代理。">
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Provider"><select value={form.aiProvider} onChange={(event) => update("aiProvider", event.target.value)} className={fieldClass}><option value="openai-compatible">OpenAI compatible</option><option value="deepseek">DeepSeek</option><option value="openai">OpenAI</option></select></Field>
                <Field label="模型"><input required value={form.aiModel} onChange={(event) => update("aiModel", event.target.value)} placeholder="deepseek-chat" className={fieldClass} /></Field>
              </div>
              <Field label="API Base URL"><input required type="url" value={form.aiBaseUrl} onChange={(event) => update("aiBaseUrl", event.target.value)} className={fieldClass} /></Field>
              <Field label="API Key"><input required type="password" autoComplete="off" value={form.aiApiKey} onChange={(event) => update("aiApiKey", event.target.value)} className={fieldClass} /></Field>
              <details className="rounded-md bg-panel px-4 py-3">
                <summary className="cursor-pointer text-sm font-medium">Indexer 重试设置</summary>
                <div className="mt-4 grid gap-4 sm:grid-cols-3">
                  <NumberField label="轮询秒数" value={form.indexerIntervalSeconds} onChange={(value) => update("indexerIntervalSeconds", value)} />
                  <NumberField label="首次重试" value={form.indexerRetryInitialSeconds} onChange={(value) => update("indexerRetryInitialSeconds", value)} />
                  <NumberField label="最大重试" value={form.indexerRetryMaximumSeconds} onChange={(value) => update("indexerRetryMaximumSeconds", value)} />
                </div>
              </details>
            </SetupSection>

            {error && <p role="alert" className="rounded-md bg-danger/10 px-4 py-3 text-sm leading-6 text-danger">{error}</p>}
            <div className="flex flex-col-reverse items-stretch justify-between gap-3 border-t border-line pt-5 sm:flex-row sm:items-center">
              <p className="flex items-center gap-2 text-xs text-stone"><Check className="h-4 w-4 text-brand" />已初始化数据库不会被后续环境变量覆盖</p>
              <button type="submit" disabled={submitting} className="inline-flex h-11 items-center justify-center gap-2 rounded-md bg-brand px-5 text-sm font-medium text-paper transition-transform active:scale-[0.98] disabled:opacity-50">
                {submitting ? <LoaderCircle className="h-4 w-4 animate-spin" /> : <ShieldCheck className="h-4 w-4" />}
                {submitStage === "testing" ? "正在验证 GitHub 与 Agent…" : submitStage === "saving" ? "正在加密保存…" : "验证并完成安装"}
              </button>
            </div>
          </div>
        </form>
      </section>
    </div>
  </main>;
}

function SetupSection({ icon, title, description, children }: { icon: ReactNode; title: string; description: string; children: ReactNode }) {
  return <section>
    <div className="flex items-start gap-3">
      <span className="mt-0.5 grid h-8 w-8 shrink-0 place-items-center rounded-md bg-tag text-brand">{icon}</span>
      <div><h2 className="text-lg font-semibold tracking-[-0.012em]">{title}</h2><p className="mt-1 text-sm leading-6 text-stone">{description}</p></div>
    </div>
    <div className="mt-5 space-y-4 sm:pl-11">{children}</div>
  </section>;
}

function Field({ label, hint, error, children }: { label: string; hint?: string; error?: string; children: ReactNode }) {
  return <label className="block text-sm font-medium text-ink">{label}{hint && <span className="ml-2 text-xs font-normal text-stone">{hint}</span>}{children}{error && <span className="mt-1 block text-xs font-normal text-danger">{error}</span>}</label>;
}

function NumberField({ label, value, onChange }: { label: string; value: number; onChange: (value: number) => void }) {
  return <Field label={label}><input required min={1} type="number" value={value} onChange={(event) => onChange(Number(event.target.value))} className={fieldClass} /></Field>;
}
