#!/bin/sh
# ledger: call the 账本助手's tools from a script in the built-in Linux.
# The App starts a bridge on 127.0.0.1 for each bash run and exports
# LEDGER_URL and LEDGER_TOKEN; outside such a run there is nothing to call.
#
#   ledger tools                  list the tools a script may call
#   ledger help <tool>            show one tool's parameters (JSON Schema)
#   ledger call <tool> [json]     call a tool; json defaults to {}, - reads stdin
#
# A call prints the tool's result (usually JSON) and exits 0, or prints the
# error to stderr and exits 1.
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY

die() { echo "ledger: $*" >&2; exit 2; }
[ -n "$LEDGER_URL" ] && [ -n "$LEDGER_TOKEN" ] || die "没有可用的工具桥：只能在助手的 bash 工具里使用"

request() { # path [body-file]
	if [ -n "$2" ]; then
		wget -q -T 600 -O - --header "Authorization: Bearer $LEDGER_TOKEN" \
			--header "Content-Type: application/json" --post-file "$2" "$LEDGER_URL$1"
	else
		wget -q -T 600 -O - --header "Authorization: Bearer $LEDGER_TOKEN" "$LEDGER_URL$1"
	fi
}

# Answers are "ok" or "error" on the first line, then the payload.
answer() {
	status=$(printf '%s\n' "$1" | head -n 1)
	body=$(printf '%s\n' "$1" | tail -n +2)
	if [ "$status" = ok ]; then
		printf '%s\n' "$body"
		return 0
	fi
	printf 'ledger: %s\n' "$body" >&2
	return 1
}

case "$1" in
tools)
	out=$(request /text/tools) || die "工具桥没有响应"
	answer "$out"
	;;
help)
	[ -n "$2" ] || die "用法：ledger help <tool>"
	out=$(request "/text/tools/$2") || die "工具桥没有响应"
	answer "$out"
	;;
call)
	[ -n "$2" ] || die "用法：ledger call <tool> [json|-]"
	tool=$2
	args=${3:-\{\}}
	tmp=$(mktemp) || die "无法创建临时文件"
	if [ "$args" = - ]; then cat > "$tmp.args"; else printf '%s' "$args" > "$tmp.args"; fi
	# {"tool": ..., "args": ...} without jq: the tool name is a plain word.
	case "$tool" in *[!a-z0-9_]*) rm -f "$tmp" "$tmp.args"; die "工具名不对：$tool";; esac
	{ printf '{"tool":"%s","args":' "$tool"; cat "$tmp.args"; printf '}'; } > "$tmp"
	rm -f "$tmp.args"
	out=$(request /text/call "$tmp")
	code=$?
	rm -f "$tmp"
	[ $code -eq 0 ] || die "工具桥没有响应"
	answer "$out"
	;;
*)
	sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
	[ -z "$1" ] || exit 2
	;;
esac
