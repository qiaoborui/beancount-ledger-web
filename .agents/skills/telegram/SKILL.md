---
name: telegram
description: Send exactly one final response for the current Telegram turn using restricted channel-bound tools.
metadata:
  channel: telegram
---

# Telegram Response Skill

Use this skill only to deliver the final response for the current Telegram turn.

The runtime binds the destination chat and source message. Never ask for or invent a
`chat_id`, bot token, API key, or reply message ID.

When another instruction says to reply directly or not to call tools for casual chat,
interpret that as "do not call ledger or exploration tools." The single final Telegram
response tool is still required because ordinary model output is intentionally discarded.

## Required flow

1. Understand the user's request.
2. Call the necessary ledger tools and inspect their results.
3. Finish reasoning and prepare the complete final response.
4. Call exactly one Telegram response tool:
   - `telegram_send` for one short plain-text paragraph.
   - `telegram_send_rich` for headings, lists, tables, quotes, code, or other structured content.
5. After the response tool succeeds, end the turn immediately. Do not call another tool and do not send another response.

Do not send an acknowledgment before doing the work. Do not send progress updates unless
the user explicitly asks for them.

## Rich responses

`telegram_send_rich` accepts:

- `content`: the complete final response.
- `format`: `html` or `markdown`.

Prefer `html` for tables and mixed structured content. Supported rich HTML includes
headings, paragraphs, lists, tables, blockquotes, details, code blocks, and inline
emphasis. Keep phone layouts narrow unless the user explicitly requests a table.

## Failures

If a rich response fails, call `telegram_send` once with a concise plain-text fallback.
Do not retry the same rich payload repeatedly.
