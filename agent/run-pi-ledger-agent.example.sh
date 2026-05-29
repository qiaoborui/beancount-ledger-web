#!/usr/bin/env bash
set -euo pipefail

# Wrapper for LEDGER_PI_COMMAND.
#
# The Go server sends PiAgentInput JSON on stdin and expects ChatResult JSON on
# stdout. Pi's JSON mode emits an event stream, so this wrapper extracts the
# final assistant text and then extracts the ChatResult object from that text.
# Optional progress events are written to stderr as `LEDGER_PI_EVENT {...}` so
# the Go server can forward live SSE updates while keeping stdout valid JSON.

input_json="$(cat)"

: "${LEDGER_PI_AGENT_NAME:=ledger-assistant}"
: "${LEDGER_PI_PROVIDER:=deepseek}"
: "${LEDGER_PI_MODEL:=deepseek-v4-flash}"
: "${LEDGER_PI_THINKING:=low}"

prompt="$(cat <<EOF
You are running as the Beancount Ledger Web Pi agent.

Input JSON:
$input_json

Use only the ledger MCP tools. For any question about existing ledger records,
call the ledger MCP tool before answering. Return only JSON shaped like:
{"message":"中文回复","plan":null,"sources":[],"entries":[]}
EOF
)"

parser="$(mktemp)"
trap 'rm -f "$parser"' EXIT

cat > "$parser" <<'PY'
import json
import re
import sys

PREFIX = "LEDGER_PI_EVENT "
assistant_text = ""
last_message = ""
tool_states = {}

def emit(kind, **payload):
    payload["type"] = kind
    sys.stderr.write(PREFIX + json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stderr.flush()

def text_from_message(message):
    if not isinstance(message, dict) or message.get("role") != "assistant":
        return ""
    parts = []
    for item in message.get("content") or []:
        if isinstance(item, dict) and item.get("type") == "text":
            parts.append(item.get("text") or "")
    return "\n".join(part for part in parts if part)

def partial_json_string_field(content, field):
    marker = re.search(r'"' + re.escape(field) + r'"\s*:\s*"', content)
    if not marker:
        return ""
    index = marker.end()
    escaped = False
    chars = []
    while index < len(content):
        char = content[index]
        if escaped:
            chars.append("\\" + char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == '"':
            break
        else:
            chars.append(char)
        index += 1
    raw = "".join(chars)
    try:
        return json.loads('"' + raw + '"')
    except json.JSONDecodeError:
        return raw.replace('\\"', '"').replace("\\n", "\n")

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

def first_value(value, keys):
    for item in walk(value):
        for key in keys:
            found = item.get(key)
            if isinstance(found, str) and found.strip():
                return found.strip()
    return ""

def tool_event_from_pi(event, status):
    name = first_value(event, ["toolName", "tool_name", "name", "tool"]) or "piTool"
    tool_call_id = first_value(event, ["toolCallId", "tool_call_id", "id"]) or name
    title = "Pi 工具调用"
    lowered = name.lower()
    if "mcp" in lowered or "ledger" in lowered:
        title = "Ledger MCP"
    return {
        "id": "pi-" + re.sub(r"[^a-zA-Z0-9_-]+", "-", tool_call_id).strip("-")[:48],
        "name": name,
        "title": title,
        "status": status,
    }

emit("status", text="Pi Agent 已启动")
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue

    event_type = event.get("type")
    assistant_event = event.get("assistantMessageEvent") or {}
    assistant_event_type = assistant_event.get("type") or ""

    if event_type == "turn_start":
        emit("status", text="Pi Agent 正在思考")
    if event_type == "message_update":
        current_text = text_from_message(event.get("message"))
        if current_text:
            assistant_text = current_text
            message = partial_json_string_field(assistant_text, "message")
            if message and message != last_message:
                last_message = message
                emit("message", text=message)
        if "tool" in assistant_event_type:
            status = "completed" if assistant_event_type.endswith("_end") or "result" in assistant_event_type else "running"
            tool = tool_event_from_pi(event, status)
            previous = tool_states.get(tool["id"])
            if previous != status:
                tool_states[tool["id"]] = status
                emit("tool", tool=tool)
    if event_type in {"message_end", "turn_end", "agent_end"}:
        candidates = []
        if isinstance(event.get("message"), dict):
            candidates.append(event["message"])
        for message in event.get("messages") or []:
            if isinstance(message, dict):
                candidates.append(message)
        for message in candidates:
            current_text = text_from_message(message)
            if current_text:
                assistant_text = current_text
                message_text = partial_json_string_field(assistant_text, "message")
                if message_text and message_text != last_message:
                    last_message = message_text
                    emit("message", text=message_text)
        if event_type == "turn_end":
            for item in event.get("toolResults") or []:
                tool = tool_event_from_pi(item, "completed")
                previous = tool_states.get(tool["id"])
                if previous != "completed":
                    tool_states[tool["id"]] = "completed"
                    emit("tool", tool=tool)

match = re.search(r"\{.*\}", assistant_text, re.S)
if not match:
    raise SystemExit("Pi did not return ChatResult JSON")

result = json.loads(match.group(0))
result.setdefault("message", "")
result.setdefault("plan", None)
result.setdefault("sources", [])
result.setdefault("entries", [])
print(json.dumps(result, ensure_ascii=False))
PY

pi \
  --provider "$LEDGER_PI_PROVIDER" \
  --model "$LEDGER_PI_MODEL" \
  --thinking "$LEDGER_PI_THINKING" \
  --mode json \
  --print \
  --no-session \
  --no-builtin-tools \
  --tools mcp \
  "$prompt" | python3 "$parser"
