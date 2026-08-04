from __future__ import annotations

from copy import deepcopy
from datetime import date
from typing import Any

from bub.tools import Tool, ToolContext


INCOME_TEMPLATES = {"salary", "bonus", "freelance", "interest", "investment", "other_income"}
EXPENSE_TEMPLATES = {
    "groceries",
    "dining",
    "coffee",
    "public_transport",
    "taxi",
    "rent",
    "utilities",
    "daily_goods",
    "clothing",
    "medical",
    "fitness",
    "entertainment",
    "subscriptions",
    "education",
    "gifts",
}


def default_draft() -> dict[str, Any]:
    return {
        "title": "我的生活账本",
        "currency": "CNY",
        "startDate": date.today().isoformat(),
        "fundingSpaces": [],
        "liabilities": [],
        "incomeCategories": [],
        "expenseCategories": [],
    }


def normalize_draft(value: dict[str, Any] | None) -> dict[str, Any]:
    draft = {**default_draft(), **deepcopy(value or {})}
    for key in ("fundingSpaces", "liabilities", "incomeCategories", "expenseCategories"):
        draft[key] = list(draft.get(key) or [])
    draft["title"] = str(draft.get("title") or "我的生活账本").strip()
    draft["currency"] = str(draft.get("currency") or "CNY").strip().upper()
    draft["startDate"] = str(draft.get("startDate") or date.today().isoformat()).strip()
    if len(draft["currency"]) != 3 or not draft["currency"].isalpha():
        raise ValueError("基础货币必须是三位字母代码")
    date.fromisoformat(draft["startDate"])
    return draft


def is_ready(draft: dict[str, Any]) -> bool:
    return bool(draft["fundingSpaces"] and draft["incomeCategories"] and draft["expenseCategories"])


def prompt(draft: dict[str, Any]) -> str:
    import json

    return f"""你是中文个人财务产品的“建账 Agent”。你必须主动引导完全不了解 Beancount 的用户，一步步完成第一本账；用户不应面对空白的聊天框，也不需要理解会计术语。

当前草案（唯一可信的已知信息）如下：{json.dumps(draft, ensure_ascii=False)}

你有工具可增删和修改这份内存草案。工具绝不会写 Git、文件、数据库或账本；只有用户稍后点击网页上的“确认并创建”才会走安全的 GitHub 写入、bean-check 和回滚保护。

行为准则：
- 首轮先自然地自我介绍，并主动问一个最有价值的问题；通常从“你平时把钱放在哪里”开始。每轮只问一个问题。
- 用户侧只使用“资金账户、收入分类、支出分类、待还款项”这些直接概念，绝不向用户展示 Assets、Expenses、Income、Liabilities、复式记账或 Beancount 路径。
- 仅把用户明确说明或确认的信息写入草案；不要臆造银行、余额、债务或生活偏好。可以给 2–4 个自然语言选项帮助回答。
- 收到信息后必须先用相应工具更新草案，再用简短中文说明你理解了什么并继续问一个最有价值的问题。绝不能只在回复中声称“已经记录”。
- 用户一次提供多个收入或支出分类时，必须优先调用 replace_income_categories 或 replace_expense_categories，一次写入完整列表；之后单项修改再使用 upsert/remove。
- account 是内部实现：每个账户都必须由你给出清晰、分层、英文的标准 Beancount 路径。不能把中文编码、拼音化，也不能让程序猜账户名。资金位置与待还款项严格使用工具规定的根路径；收入位于 Income:，消费位于 Expenses:。
- 只有当草案至少有一个资金账户、一个收入分类和一个支出分类时，才能调用 present_onboarding_plan，再告知用户可以检查账本结构并确认创建。用户即使在方案就绪后继续修改，也必须再次调用该工具才能恢复确认状态。
- 只在确实要变更草案或展示方案时调用工具；正常对话直接回复。"""


def _schema(properties: dict[str, Any], required: list[str] | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {"type": "object", "properties": properties, "additionalProperties": False}
    if required:
        result["required"] = required
    return result


def _string(description: str) -> dict[str, Any]:
    return {"type": "string", "description": description}


def _state(context: ToolContext) -> tuple[dict[str, Any], dict[str, Any]]:
    draft = context.state["onboarding_draft"]
    context.state["onboarding_ready"] = False
    return draft, {"draft": draft, "ready": False}


def _validate_account(account: str, root: str) -> str:
    account = account.strip()
    if not account.startswith(root + ":") or any(ord(ch) > 127 for ch in account):
        raise ValueError(f"account 必须是 {root}: 开头的英文 Beancount 路径")
    return account


def _upsert(items: list[dict[str, Any]], item: dict[str, Any], key: str) -> None:
    for index, current in enumerate(items):
        if current.get(key) == item.get(key):
            items[index] = item
            return
    items.append(item)


def onboarding_tools() -> dict[str, Tool]:
    async def set_profile(context: ToolContext, **values: Any) -> dict[str, Any]:
        draft, _ = _state(context)
        for source, target in (("title", "title"), ("currency", "currency"), ("startDate", "startDate")):
            if values.get(source):
                draft[target] = str(values[source]).strip()
        context.state["onboarding_draft"] = normalize_draft(draft)
        return {"draft": context.state["onboarding_draft"], "ready": False}

    async def upsert_funding(context: ToolContext, **values: Any) -> dict[str, Any]:
        draft, result = _state(context)
        kind = str(values["kind"]).strip()
        roots = {"cash": "Assets:Cash", "bank_card": "Assets:Bank", "digital_wallet": "Assets:Wallet", "savings": "Assets:Savings", "investment": "Assets:Investment"}
        if kind not in roots:
            raise ValueError("资金账户类型无效")
        item = {
            "kind": kind,
            "name": str(values["name"]).strip(),
            "account": _validate_account(str(values["account"]), roots[kind]),
            "currency": str(values.get("currency") or draft["currency"]).strip().upper(),
            "openingBalance": str(values.get("openingBalance") or "").strip(),
        }
        _upsert(draft["fundingSpaces"], item, "name")
        return result

    async def upsert_liability(context: ToolContext, **values: Any) -> dict[str, Any]:
        draft, result = _state(context)
        kind = str(values["kind"]).strip()
        roots = {"credit_card": "Liabilities:CreditCard", "consumer_loan": "Liabilities:Loan", "other_debt": "Liabilities:Other"}
        if kind not in roots:
            raise ValueError("待还款类型无效")
        item = {
            "kind": kind,
            "name": str(values["name"]).strip(),
            "account": _validate_account(str(values["account"]), roots[kind]),
            "currency": str(values.get("currency") or draft["currency"]).strip().upper(),
            "openingBalance": str(values.get("openingBalance") or "").strip(),
        }
        _upsert(draft["liabilities"], item, "name")
        return result

    async def remove_named(context: ToolContext, collection: str, name: str) -> dict[str, Any]:
        draft, result = _state(context)
        before = len(draft[collection])
        draft[collection] = [item for item in draft[collection] if item.get("name") != name.strip()]
        if len(draft[collection]) == before:
            raise ValueError("没有找到要删除的项目")
        return result

    async def change_category(
        context: ToolContext,
        collection: str,
        root: str,
        templates: set[str],
        **values: Any,
    ) -> dict[str, Any]:
        draft, result = _state(context)
        template_key = str(values.get("templateKey") or "").strip()
        custom_name = str(values.get("customName") or "").strip()
        if bool(template_key) == bool(custom_name):
            raise ValueError("templateKey 和 customName 必须且只能提供一个")
        if template_key and template_key not in templates:
            raise ValueError("不支持的预设分类")
        item = {
            "templateKey": template_key,
            "customName": custom_name,
            "account": _validate_account(str(values["account"]), root),
        }
        key = "templateKey" if template_key else "customName"
        _upsert(draft[collection], item, key)
        return result

    async def replace_categories(
        context: ToolContext,
        collection: str,
        root: str,
        templates: set[str],
        categories: list[dict[str, Any]],
    ) -> dict[str, Any]:
        if not categories:
            raise ValueError("分类列表不能为空")
        draft, result = _state(context)
        normalized: list[dict[str, Any]] = []
        for values in categories:
            template_key = str(values.get("templateKey") or "").strip()
            custom_name = str(values.get("customName") or "").strip()
            if bool(template_key) == bool(custom_name) or (template_key and template_key not in templates):
                raise ValueError("分类名称无效")
            normalized.append(
                {
                    "templateKey": template_key,
                    "customName": custom_name,
                    "account": _validate_account(str(values["account"]), root),
                }
            )
        draft[collection] = normalized
        return result

    async def remove_category(context: ToolContext, collection: str, **values: Any) -> dict[str, Any]:
        draft, result = _state(context)
        template_key = str(values.get("templateKey") or "").strip()
        custom_name = str(values.get("customName") or "").strip()
        if bool(template_key) == bool(custom_name):
            raise ValueError("请提供且只提供 templateKey 或 customName")
        before = len(draft[collection])
        draft[collection] = [
            item
            for item in draft[collection]
            if item.get("templateKey") != template_key or item.get("customName") != custom_name
        ]
        if len(draft[collection]) == before:
            raise ValueError("没有找到这个分类")
        return result

    async def present(context: ToolContext) -> dict[str, Any]:
        draft = context.state["onboarding_draft"]
        if not is_ready(draft):
            raise ValueError("草案尚不能确认：至少需要一个资金账户、收入分类和支出分类")
        context.state["onboarding_ready"] = True
        return {"draft": draft, "ready": True}

    string = _string
    category_schema = _schema(
        {"templateKey": string("可选预设分类 key"), "customName": string("可选自定义中文名称"), "account": string("英文 Beancount 路径")},
        ["account"],
    )
    definitions: list[tuple[str, str, dict[str, Any], Any]] = [
        ("set_ledger_profile", "更新账本名称、基础货币或开始日期。", _schema({"title": string("账本名称"), "currency": string("三位基础货币"), "startDate": string("YYYY-MM-DD")}), set_profile),
        ("upsert_funding_space", "新增或更新一个资金账户。", _schema({"kind": {"type": "string", "enum": ["cash", "bank_card", "digital_wallet", "savings", "investment"]}, "name": string("中文名称"), "account": string("英文 Beancount 路径"), "currency": string("货币"), "openingBalance": string("期初余额")}, ["kind", "name", "account"]), upsert_funding),
        ("remove_funding_space", "删除一个资金账户。", _schema({"name": string("中文名称")}, ["name"]), lambda context, name: remove_named(context, "fundingSpaces", name)),
        ("upsert_liability", "新增或更新一个待还款项。", _schema({"kind": {"type": "string", "enum": ["credit_card", "consumer_loan", "other_debt"]}, "name": string("中文名称"), "account": string("英文 Beancount 路径"), "currency": string("货币"), "openingBalance": string("待还金额")}, ["kind", "name", "account"]), upsert_liability),
        ("remove_liability", "删除一个待还款项。", _schema({"name": string("中文名称")}, ["name"]), lambda context, name: remove_named(context, "liabilities", name)),
        ("upsert_income_category", "新增或更新一个收入分类。", category_schema, lambda context, **values: change_category(context, "incomeCategories", "Income", INCOME_TEMPLATES, **values)),
        ("replace_income_categories", "一次性替换完整收入分类列表。", _schema({"categories": {"type": "array", "items": category_schema}}, ["categories"]), lambda context, categories: replace_categories(context, "incomeCategories", "Income", INCOME_TEMPLATES, categories)),
        ("remove_income_category", "删除一个收入分类。", _schema({"templateKey": string("预设 key"), "customName": string("自定义名称")}), lambda context, **values: remove_category(context, "incomeCategories", **values)),
        ("upsert_expense_category", "新增或更新一个支出分类。", category_schema, lambda context, **values: change_category(context, "expenseCategories", "Expenses", EXPENSE_TEMPLATES, **values)),
        ("replace_expense_categories", "一次性替换完整支出分类列表。", _schema({"categories": {"type": "array", "items": category_schema}}, ["categories"]), lambda context, categories: replace_categories(context, "expenseCategories", "Expenses", EXPENSE_TEMPLATES, categories)),
        ("remove_expense_category", "删除一个支出分类。", _schema({"templateKey": string("预设 key"), "customName": string("自定义名称")}), lambda context, **values: remove_category(context, "expenseCategories", **values)),
        ("present_onboarding_plan", "草案完整后展示确认创建按钮。", _schema({}), present),
    ]
    return {
        name: Tool(name=name, description=description, parameters=parameters, handler=handler, context=True)
        for name, description, parameters, handler in definitions
    }
