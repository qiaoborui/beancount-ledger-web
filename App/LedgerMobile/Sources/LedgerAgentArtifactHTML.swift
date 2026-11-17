import Foundation

/// Advanced artifacts: a page the model writes in HTML, CSS and JavaScript,
/// for what the native blocks cannot draw. The app wraps the body in its own
/// document whose first element is a Content-Security-Policy allowing no
/// network at all (no fetch, images, fonts, frames or forms from anywhere),
/// and the web view adds a content rule list blocking every load and refuses
/// every navigation. The only way out is `window.ledger`: read-only BQL
/// queries, `ledger://` links, and a follow-up question after a tap.
enum LedgerAgentArtifactHTML {
    static let maximumBytes = 200_000
    /// Queries one page load may run.
    static let maximumQueries = 60
    static let maximumQueryLength = 4_000
    /// Rows one query hands the page.
    static let maximumRows = 5_000
    /// Seconds between two follow-up questions from a page.
    static let askInterval: TimeInterval = 3

    static let contentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
        + "img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src 'none'; "
        + "child-src 'none'; worker-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"

    /// Blocks every load but the page itself and inline data. WebKit's rule
    /// regexes have no alternation (`|`), so each allowed scheme is its own
    /// rule; one `|` makes the whole list fail to compile.
    static let contentRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},"#
        + #"{"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},"#
        + #"{"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},"#
        + #"{"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}}]"#

    /// The header line and the HTML after it, or nil when either is missing.
    static func split(_ source: String) -> ([String: Any], String)? {
        guard let newline = source.firstIndex(of: "\n") else { return nil }
        let line = source[..<newline].trimmingCharacters(in: .whitespaces)
        let body = source[source.index(after: newline)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("{"), body.contains("<"),
              let header = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        return (header, body)
    }

    /// Whether the page may run a query: one read-only statement.
    static func allows(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumQueryLength else { return false }
        let first = trimmed.prefix { $0.isLetter }.lowercased()
        return ["select", "balances", "journal"].contains(first)
    }

    /// A query's result as plain values for the page: columns with name and
    /// type, and rows of numbers, strings, booleans, arrays and nulls. Money
    /// comes from the engine in cents and goes to the page in yuan, as the
    /// model's own query tool reports it.
    static func reply(_ result: BQLResult) -> [String: Any] {
        func value(_ cell: BQLCell) -> Any {
            switch cell {
            case .null: NSNull()
            case let .bool(flag): flag
            case let .number(number): number
            case let .string(text): text
            case let .array(items): items.map(value)
            case let .object(fields): fields.mapValues(value)
            }
        }
        let money = result.columns.map { $0.type == "money" }
        let rows = result.rows.prefix(maximumRows).map { row in
            row.enumerated().map { index, cell -> Any in
                if index < money.count, money[index], case let .number(cents) = cell { return cents / 100 }
                return value(cell)
            }
        }
        return ["columns": result.columns.map { ["name": $0.name, "type": $0.type] },
                "rows": rows,
                "truncated": result.rows.count > rows.count || result.rowCount > result.rows.count]
    }

    struct Context: Equatable, Sendable {
        var title: String
        var today: String
        var currency: String
    }

    /// The document the web view loads: the policy, theme and bridge first,
    /// then the model's body.
    static func document(body: String, context: Context) -> String {
        """
        <!doctype html>
        <html lang="zh-Hans"><head>
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="light dark">
        <title>\(escaped(context.title))</title>
        <style>\(theme)</style>
        <script>\(bridge(context))</script>
        </head><body>
        \(body)
        </body></html>
        """
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The app's palette as CSS variables, light and dark, and quiet defaults.
    static let theme = """
    :root{--page:#FBFAF8;--sunken:#F1EFE9;--ink:#14100C;--secondary:#453E36;--meta:#6F675A;--rule:#E2DED4;\
    --rule-strong:#C8C2B4;--income:#0D5346;--expense:#96401F;--blue:#0A64D6;--orange:#C46A12;--purple:#7445B5;\
    --teal:#147D86;color-scheme:light dark}
    @media (prefers-color-scheme:dark){:root{--page:#121110;--sunken:#1B1918;--ink:#F6F3EE;--secondary:#C4BCB0;\
    --meta:#9A9086;--rule:#2B2825;--rule-strong:#423C36;--income:#4FBFAB;--expense:#CF7A52;--blue:#5AA2FF;\
    --orange:#F0A04B;--purple:#B48CF0;--teal:#4CC3C9}}
    *{box-sizing:border-box}
    html,body{margin:0;background:var(--page);color:var(--ink);-webkit-text-size-adjust:100%}
    body{padding:4px 0 32px;font:15px/1.55 -apple-system,"PingFang SC",system-ui,sans-serif}
    .num,td,th{font-variant-numeric:tabular-nums}
    table{border-collapse:collapse;width:100%}
    th,td{padding:7px 6px;border-bottom:1px solid var(--rule);text-align:left}
    th{color:var(--meta);font-weight:500;font-size:13px}
    a{color:inherit}
    button,select,input{font:inherit;color:var(--ink);background:var(--sunken);border:1px solid var(--rule);border-radius:8px;padding:6px 12px}
    """

    /// `window.ledger`, frozen so the page cannot swap it out. A tap on a
    /// `ledger://` link goes through `open` instead of navigating.
    static func bridge(_ context: Context) -> String {
        let constants = (try? JSONSerialization.data(withJSONObject: [context.today, context.currency]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\",\"\"]"
        return """
        (()=>{const h=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.ledger;
        const post=(op,p)=>h?h.postMessage(Object.assign({op},p||{})):Promise.reject(new Error("账本不可用"));
        const active=()=>!!(navigator.userActivation&&navigator.userActivation.isActive);
        const [today,currency]=\(constants);
        const format=(n,d)=>Number(n).toLocaleString("en-US",{minimumFractionDigits:0,maximumFractionDigits:d==null?2:d});
        const trim=(s)=>s.replace(/\\.?0+$/,"");
        const api={today,currency,format,
        query:(bql)=>post("query",{bql:String(bql)}),
        rows:async(bql)=>{const r=await post("query",{bql:String(bql)});return r.rows.map(row=>Object.fromEntries(r.columns.map((c,i)=>[c.name,row[i]])));},
        open:(url)=>post("open",{url:String(url),active:active()}),
        ask:(text)=>post("ask",{text:String(text),active:active()}),
        compact:(n)=>{const a=Math.abs(n);return a>=1e8?trim((n/1e8).toFixed(2))+"亿":a>=1e4?trim((n/1e4).toFixed(2))+"万":format(n);}};
        Object.freeze(api);Object.defineProperty(window,"ledger",{value:api,writable:false,configurable:false});
        document.addEventListener("click",e=>{const a=e.target.closest&&e.target.closest("a[href]");
        if(a&&a.getAttribute("href").toLowerCase().startsWith("ledger://")){e.preventDefault();api.open(a.getAttribute("href"));}},true);})();
        """
    }
}
