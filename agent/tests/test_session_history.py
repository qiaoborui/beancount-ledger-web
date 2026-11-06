from __future__ import annotations

from types import SimpleNamespace

from ledger_agent_service.session_history import (
    MAX_CONVERSATION_LIMIT,
    MAX_TRANSCRIPT_MESSAGES,
    clip_history_text,
    conversation_messages,
    message_text,
    rank_conversations,
    summarize_conversation,
    transcript_messages,
)


def entry(role: str, content: object, date: str) -> SimpleNamespace:
    return SimpleNamespace(payload={"role": role, "content": content}, date=date)


def tool_entry(date: str) -> SimpleNamespace:
    return SimpleNamespace(payload={"calls": []}, date=date)


def test_message_text_reads_strings_and_text_blocks() -> None:
    assert message_text({"content": "本月支出 1,280.00 元"}) == "本月支出 1,280.00 元"
    assert message_text({"content": [{"type": "text", "text": "第一段"}, {"type": "image"}, {"type": "text", "text": "第二段"}]}) == "第一段第二段"
    assert message_text({"content": [{"type": "image"}]}) == ""
    assert message_text({}) == ""


def test_conversation_messages_skip_non_chat_entries_and_empty_text() -> None:
    entries = [
        tool_entry("2026-11-01T00:00:00Z"),
        entry("system", "隐藏指令", "2026-11-01T00:00:01Z"),
        entry("user", "  ", "2026-11-01T00:00:02Z"),
        entry("user", "这个月外食花了多少？", "2026-11-01T00:00:03Z"),
        entry("assistant", [{}, {"type": "text", "text": "本月餐饮 1,280.00 元。"}], "2026-11-01T00:00:04Z"),
    ]

    assert conversation_messages(entries) == [
        ("user", "这个月外食花了多少？", "2026-11-01T00:00:03Z"),
        ("assistant", "本月餐饮 1,280.00 元。", "2026-11-01T00:00:04Z"),
    ]


def test_clip_history_text_collapses_whitespace_and_marks_truncation() -> None:
    assert clip_history_text("第一行\n\n第二行", 40) == "第一行 第二行"
    clipped = clip_history_text("很长的记录" * 40, 20)
    assert len(clipped) == 20
    assert clipped.endswith("…")


def test_summarize_conversation_describes_one_tape() -> None:
    entries = [
        entry("user", "这个月外食花了多少？", "2026-11-01T09:00:00Z"),
        entry("assistant", "本月餐饮支出合计 1,280.00 元。", "2026-11-01T09:00:05Z"),
        tool_entry("2026-11-01T09:00:03Z"),
        entry("user", "那上周呢？", "2026-11-02T10:00:00Z"),
        entry("assistant", "上周 320.00 元。", "2026-11-02T10:00:04Z"),
    ]

    summary = summarize_conversation("workspace__one", entries)

    assert summary == {
        "session": "workspace__one",
        "startedAt": "2026-11-01T09:00:00Z",
        "updatedAt": "2026-11-02T10:00:04Z",
        "turns": 2,
        "firstQuestion": "这个月外食花了多少？",
        "lastMessage": "上周 320.00 元。",
    }
    assert summarize_conversation("workspace__empty", [tool_entry("2026-11-01T00:00:00Z")]) is None


def test_rank_conversations_sorts_newest_first_and_bounds_the_limit() -> None:
    conversations = [
        {"session": "old", "updatedAt": "2026-10-01T00:00:00Z", "firstQuestion": "预算", "lastMessage": "旧"},
        {"session": "new", "updatedAt": "2026-11-01T00:00:00Z", "firstQuestion": "外卖", "lastMessage": "新"},
        None,
    ]

    assert [item["session"] for item in rank_conversations(conversations, 10)] == ["new", "old"]
    assert [item["session"] for item in rank_conversations(conversations, 1)] == ["new"]
    assert len(rank_conversations(conversations * 40, 999)) <= MAX_CONVERSATION_LIMIT


def test_rank_conversations_matches_a_keyword_without_case_folding_the_ledger() -> None:
    conversations = [
        {"session": "one", "updatedAt": "2026-11-02T00:00:00Z", "firstQuestion": "Budget review", "lastMessage": "done"},
        {"session": "two", "updatedAt": "2026-11-01T00:00:00Z", "firstQuestion": "外卖", "lastMessage": "1,280.00 元"},
    ]

    assert [item["session"] for item in rank_conversations(conversations, 5, "budget")] == ["one"]
    assert [item["session"] for item in rank_conversations(conversations, 5, "1,280")] == ["two"]
    assert rank_conversations(conversations, 5, "不存在") == []


def test_transcript_messages_keep_the_tail_and_line_breaks() -> None:
    entries = [entry("user", f"问题 {index}", f"2026-11-01T00:00:0{index % 10}Z") for index in range(80)]
    entries.append(entry("assistant", "第一行\n第二行", "2026-11-01T00:00:09Z"))

    messages = transcript_messages(entries)

    assert len(messages) == MAX_TRANSCRIPT_MESSAGES
    assert messages[-1] == {"role": "assistant", "content": "第一行\n第二行"}
    assert messages[0]["content"] == f"问题 {81 - MAX_TRANSCRIPT_MESSAGES}"

    clipped = transcript_messages([entry("user", "长" * 5000, "2026-11-01T00:00:00Z")])
    assert clipped[0]["content"].endswith("…")
    assert len(clipped[0]["content"]) == 1200
