"""Read-only helpers for browsing the ledger agent's earlier conversations.

The agent keeps one Bub tape per conversation. Replying from memory of another
session means reading those tapes back, which is pure shaping: clip each message
to a readable length, rank conversations by their last entry, and hand the model
an opaque session handle it can pass back to read a transcript.
"""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

DEFAULT_CONVERSATION_LIMIT = 10
MAX_CONVERSATION_LIMIT = 25
MAX_TRANSCRIPT_MESSAGES = 60
SUMMARY_TEXT_LIMIT = 240
TRANSCRIPT_TEXT_LIMIT = 1200

_ROLES = ("user", "assistant")


def clip_history_text(value: object, limit: int) -> str:
    """Collapse whitespace and keep a single readable excerpt."""
    text = " ".join(str(value or "").split())
    if len(text) <= limit:
        return text
    return text[: max(limit - 1, 1)].rstrip() + "…"


def message_text(message: dict[str, Any]) -> str:
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list | tuple):
        parts: list[str] = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(str(block.get("text") or ""))
        return "".join(parts)
    return ""


def conversation_message(entry: Any) -> tuple[str, str, str] | None:
    """Return (role, text, date) for one tape entry, or None when it is not chat."""
    payload = getattr(entry, "payload", None)
    if not isinstance(payload, dict):
        return None
    role = str(payload.get("role") or "")
    text = message_text(payload).strip()
    if role not in _ROLES or not text:
        return None
    return role, text, str(getattr(entry, "date", "") or "")


def conversation_messages(entries: Iterable[Any]) -> list[tuple[str, str, str]]:
    messages: list[tuple[str, str, str]] = []
    for entry in entries:
        message = conversation_message(entry)
        if message is not None:
            messages.append(message)
    return messages


def summarize_conversation(tape: str, entries: Iterable[Any]) -> dict[str, Any] | None:
    """Describe one conversation well enough for the model to choose it."""
    messages = conversation_messages(entries)
    if not messages:
        return None
    questions = [text for role, text, _ in messages if role == "user"]
    role, last_text, last_date = messages[-1]
    return {
        "session": tape,
        "startedAt": messages[0][2],
        "updatedAt": last_date,
        "turns": len(questions),
        "firstQuestion": clip_history_text(questions[0] if questions else messages[0][1], SUMMARY_TEXT_LIMIT),
        "lastMessage": clip_history_text(last_text, SUMMARY_TEXT_LIMIT),
    }


def rank_conversations(
    conversations: Iterable[dict[str, Any] | None],
    limit: int,
    query: str = "",
) -> list[dict[str, Any]]:
    """Newest first, optionally narrowed by a case-insensitive keyword."""
    present = [conversation for conversation in conversations if conversation]
    present.sort(key=lambda conversation: conversation["updatedAt"], reverse=True)
    needle = query.strip().lower()
    if needle:
        present = [
            conversation
            for conversation in present
            if needle in f"{conversation['firstQuestion']} {conversation['lastMessage']}".lower()
        ]
    bounded = max(1, min(int(limit), MAX_CONVERSATION_LIMIT))
    return present[:bounded]


def transcript_text(value: object, limit: int = TRANSCRIPT_TEXT_LIMIT) -> str:
    """Keep line breaks: an earlier reply may carry a ledger draft."""
    text = str(value or "").strip()
    if len(text) <= limit:
        return text
    return text[: max(limit - 1, 1)].rstrip() + "…"


def transcript_messages(entries: Iterable[Any], limit: int = MAX_TRANSCRIPT_MESSAGES) -> list[dict[str, str]]:
    messages = conversation_messages(entries)
    bounded = max(1, min(int(limit), MAX_TRANSCRIPT_MESSAGES))
    return [
        {"role": role, "content": transcript_text(text)}
        for role, text, _ in messages[-bounded:]
    ]
