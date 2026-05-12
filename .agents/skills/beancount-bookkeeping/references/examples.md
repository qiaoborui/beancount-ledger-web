# Beancount Bookkeeping Examples

## Multi-line expenses

Input:

```text
昨天 星巴克 38 招行信用卡
今天 午餐 56 支付宝
5/8 打车 24 微信
```

Expected behavior:

- Parse 3 independent transactions.
- Preview all 3.
- Ask for confirmation before append.

## Income

Input:

```text
今天 工资 30000 招行储蓄卡
```

Expected postings:

- Asset account positive.
- Income account negative.

## Credit card repayment

Input:

```text
今天 招行储蓄卡还招行信用卡 5000
```

Expected postings:

- Checking/savings asset negative.
- Credit card liability positive.

## Needs review

Input:

```text
昨天 买东西 99
```

Expected behavior:

- Use a reasonable account/category fallback.
- Mark `needsReview: true`.
- Ask which payment account/category should be used before writing.
