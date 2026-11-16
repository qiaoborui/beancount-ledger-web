"""Call the 账本助手's tools from a Python script in the built-in Linux.

    from ledger import call, tools, describe
    rows = call("run_bql", query="SELECT account, sum(position) GROUP BY account")

call() returns the tool's result parsed as JSON when it is JSON, and the
text otherwise; a tool error raises LedgerError. The App starts a bridge on
127.0.0.1 for each bash run and exports LEDGER_URL and LEDGER_TOKEN, so this
works only inside the assistant's bash tool.
"""
import json
import os
import urllib.error
import urllib.request

__all__ = ["LedgerError", "call", "tools", "describe"]


class LedgerError(Exception):
    pass


_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _request(path, body=None):
    url, token = os.environ.get("LEDGER_URL"), os.environ.get("LEDGER_TOKEN")
    if not url or not token:
        raise LedgerError("没有可用的工具桥：只能在助手的 bash 工具里使用")
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(url + path, data=data, headers={
        "Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with _opener.open(request, timeout=600) as response:
            answer = json.loads(response.read().decode("utf-8"))
    except urllib.error.URLError as error:
        raise LedgerError("工具桥没有响应: %s" % error) from None
    if not answer.get("ok"):
        raise LedgerError(answer.get("error") or "调用失败")
    return answer


def call(tool, args=None, **kwargs):
    """Call one tool; keyword arguments are its parameters."""
    params = dict(args or {})
    params.update(kwargs)
    text = _request("/call", {"tool": tool, "args": params})["result"]
    try:
        return json.loads(text)
    except ValueError:
        return text


def tools():
    """The tools a script may call, as [{"name", "description"}]."""
    return _request("/tools")["tools"]


def describe(tool):
    """One tool's description and parameters (JSON Schema)."""
    return _request("/tools/" + tool)["tool"]
