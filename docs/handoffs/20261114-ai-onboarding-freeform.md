# 20261114-ai-onboarding-freeform

- Status: active (draft PR, CI Gate green)
- Last updated: 2026-11-14 (+08:00)
- Branch: `codex/ai-onboarding-freeform`, based on `main` at `8ef3888b`
- PR: draft, opened from this branch
- Part of the AI-native ledger assistant batch (sub-task C); the shared
  conventions live in the coordinator's `00-common.md`.

## Goal

Stop AI 开账 from walking the user through a fixed five-step script and make it
behave like an assistant: open with one open question, write everything the
user says into the draft at once, ask only for what is still missing and
matters, offer defaults it can infer, and extend on its own. Show progress as
what the draft already holds rather than which step the conversation is on,
and hand the created ledger to the full assistant with a greeting and next
steps.

## Decisions

- The onboarding prompt (`server/mobileagent/onboarding.go`) now states the
  information a ledger needs, the completion criteria, and how to behave
  (extract first, ask what is missing, default and say so, ask one or two
  things at a time, refine on the user's own situation). It no longer names
  any step or order. The hard constraints survive verbatim in spirit: no
  Beancount words or account paths to the user, no invented balances, tools
  before "记下了", the same account-path rules, short replies.
- `ask_user` stays the way to ask anything with clear options, but the prompt
  caps it at "two or three cards in the whole conversation" and asks for
  free-text questions for amounts, names and dates, so the page does not feel
  like a form.
- The draft note in front of every user message now says what the draft is
  still missing (`还缺资金账户、收入分类`), so the model reads the next
  question off the draft and not off a remembered order. The "funds" test is
  the existing one: at least one `Assets:` account, so a lone credit card
  still leaves 资金账户 open. Amounts owed and the profile are never listed as
  missing — they have defaults.
- `LedgerOnboardingStep` (funds/debts/income/expenses/review) is gone. The new
  `LedgerOnboardingCoverage` derives four parts and their counts from the
  draft alone, and its `isComplete` is asserted equal to `draft.isComplete`
  in the tests. The bar shows one pill per part (`资金账户 2`,
  `待还款项 1`, `收入分类`, `支出分类`) and one line: `还缺 …` or `资料齐了，
  可以看结构`, replaced by `方案已就绪，检查后确认创建` once the model presents.
- After 确认创建, the app writes a `LedgerAgentOpening` from the draft (what
  was created) plus four next steps — 帮我导入一份账单 / 帮我设置记账提醒 /
  帮我记第一笔账 / 帮我调整首页 — and sets it as
  `LedgerAgentSessions.pendingOpening`. `LedgerAgentView` takes it after
  `bind`, so the greeting lands in the new ledger's conversation and not the
  previous one's; a tap on a step is sent as the first question to the full
  assistant.
- The greeting is an ordinary assistant message the app writes
  (`LedgerAgentConversation.greet`), not a `ledger://agent?q=` route: the route
  would send a synthetic user question and spend a model turn, while the brief
  wants a greeting that costs none. Because `LedgerAgentHistory` only replays
  paired question/answer turns, the greeting never reaches the model as
  something it said; the first tapped step is the first question. `greet` also
  sets the composer's hint to the first step, so the greeting does not trigger
  a `predictNext` request.
- Presenting the assistant cannot happen inside the onboarding sheet's
  dismissal (SwiftUI/UIKit drops a cover requested while another presentation
  is going away). `LedgerSession.openAgent(with:)` records the greeting, waits
  for `aiOnboardingOnScreen` to clear and one more beat for the dismissal
  animation, then sets `agentPresented`. The onboarding page sets that flag in
  `onAppear`/`onDisappear`; giving up is silent and leaves the greeting stored
  for the next time the assistant is opened.
- No data-model changes: no account notes or institutions. The brief allows
  extending the draft only where necessary, and nothing in the new flow needs
  it.

## Assumed conversation shapes and how the prompt answers them

1. **One breath, everything at once** — "我用招行卡，工资一万二，平时吃饭打车
   花得多，还有张信用卡欠两千". The prompt asks for one open question first,
   then extraction of everything from the answer: bank card with no balance
   (left empty, asked once at most), income categories 工资, expense 餐饮/交通,
   and the card recorded as 待还款项 with 2000. Missing: nothing but a funds
   balance and the savings question is skipped because the draft already
   satisfies the completion criteria; the model calls
   `present_onboarding_plan` and summarises what is default (账本名称、本位币、
   期初日期).
2. **Drip feed, one detail per message** — each message is written into the
   draft before replying; the note tells the model what is still missing, so it
   never re-asks an answered part, and it asks at most one or two related
   things, picking the most valuable next question itself (a balance before a
   missing category when the categories already allow daily use). No step
   counter can fall out of sync because there is none.
3. **Multi-currency** — "我有一张港卡" makes the model ask which currency;
   the account keeps `currency: HKD` while the ledger stays CNY, and the app
   opens the categories with every currency the ledger holds. The prompt makes
   this an explicit extension rule rather than something to discover late.
4. **Changing their mind mid-way** — a new currency, a renamed account or a
   deleted category is written first and repeated back; `change` clears
   `ready`, and the prompt requires `present_onboarding_plan` again before
   确认创建 reappears, so the user never confirms a plan the model did not
   show.
5. **"你看着办"** — the prompt forbids more questions then: the model fills a
   complete plan (common account shapes, common income/expense categories,
   balances left empty rather than invented), presents it, and says what it
   decided and what can be changed.

## Validation

- `server/`: `go test ./...` and `go build ./cmd/ledger-web` were run on this
  branch. `mobileagent` passes, including the new
  `TestOnboardingPromptStatesGoalsNotAFixedSequence` (no `第 1 步`/`分四步`/
  `每轮只推进一步`, and the goal, completion criteria, extension rules and kept
  constraints are present) and `TestOnboardingDraftNoteNamesWhatIsMissing`
  (a lone credit card still leaves 资金账户 open; a ready draft says so).
  Two failures in the full `go test ./...` run are pre-existing and
  environmental: `TestFeedNeverCutsACharacter` (a flush-interval race that also
  fails on `origin/main` at `8ef3888b` under `-count=10`) and
  `TestGitHubWriteValidationLargeLedgerPerformance` (bean-check budgets on this
  machine; also fails on `origin/main`).
- Swift: self-reviewed only (no Xcode on this machine), with portable unit
  tests added to `App/LedgerMobile/Tests/LedgerOnboardingConversationTests.swift`:
  coverage derivation and its agreement with `draft.isComplete`, the greeting
  text and its four single-tap steps, `greet` writing one app-authored
  message that is not replayed as model history, and
  `LedgerAgentSessions.takeOpening` consuming the greeting once.
- CI (`Gate`) on the draft PR: green — the iPad/iPhone app build compiles the
  new view code, `swift test` runs the new portable tests.
- Not tested: a live model conversation (no key or scripted harness in this
  worktree), the actual presentation timing of the cover after 确认创建, and a
  real device layout for the new progress pills.

## Next

1. Review the PR together with the other AI-native sub-tasks; the coordinator
   wires the new settings page.
2. When a model is available, run the five scenarios above through the app and
   tune the wording of the prompt and the four next steps if any feels long.
3. A release is needed with the rest of the batch: 需要发版：新增 AI 开账按情况
   自由追问，并在建好后自动把新账本交给账本助手继续配置.
