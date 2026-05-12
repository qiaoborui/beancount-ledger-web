# Web API Contract

These endpoints are available inside the existing Next.js web app. They require the normal web authentication/session.

## Parse natural language

```http
POST /api/ai/parse
Content-Type: application/json

{ "input": "昨天 星巴克 38 招行信用卡\n今天 午餐 56 支付宝" }
```

Response:

```json
{
  "entries": [
    {
      "kind": "transaction",
      "date": "2026-05-08",
      "payee": "星巴克",
      "narration": "咖啡",
      "postings": [
        { "account": "Expenses:Food:Coffee", "amount": "38.00", "currency": "CNY" },
        { "account": "Liabilities:CN:CMB:CreditCard", "amount": "-38.00", "currency": "CNY" }
      ],
      "confidence": 0.95,
      "needsReview": false,
      "questions": []
    }
  ],
  "entry": { "...": "first entry, compatibility only" }
}
```

Use `entries`; `entry` is only for backward compatibility.

## Append batch

```http
POST /api/ledger/append-batch
Content-Type: application/json

{ "entries": [/* LedgerEntry objects */] }
```

Response:

```json
{
  "ok": true,
  "count": 2,
  "beanTexts": ["..."]
}
```

## Transaction schema

Each parsed transaction uses:

```json
{
  "kind": "transaction",
  "date": "YYYY-MM-DD",
  "payee": "商户/对方",
  "narration": "简短说明",
  "postings": [
    { "account": "账户名", "amount": "38.00", "currency": "CNY" },
    { "account": "账户名", "amount": "-38.00", "currency": "CNY" }
  ],
  "confidence": 0.0,
  "needsReview": false,
  "questions": []
}
```
