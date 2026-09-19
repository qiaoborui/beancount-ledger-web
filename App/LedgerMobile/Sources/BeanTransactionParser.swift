import Foundation
#if canImport(LedgerCore)
import LedgerCore
#endif

enum BeanTransactionParser {
    struct Parsed: Decodable, Sendable {
        struct Result: Decodable, Sendable {
            struct Entry: Decodable, Sendable { let kind: String }
            let entries: [Entry]
        }
        struct Diagnostic: Decodable, Sendable { let message: String }
        let ok: Bool
        let result: Result?
        let diagnostics: [Diagnostic]
    }
    /// The native engine checks directive types; the canonical validator later
    /// checks the original bytes in the complete destination workspace.
    static func transactionCount(_ text: String) throws -> Int {
        guard !text.isEmpty, text.utf8.count <= 2_000_000 else { throw BookkeepingError.invalidModelResponse }
        #if canImport(LedgerCore)
        let request = try JSONSerialization.data(withJSONObject: ["version": 1, "filename": "import.bean", "text": text])
        let response = MobilecoreParseTextJSON(String(decoding: request, as: UTF8.self))
        let parsed = try JSONDecoder().decode(Parsed.self, from: Data(response.utf8))
        guard parsed.ok else { throw BookkeepingError.reviewRequired(parsed.diagnostics.map(\.message).joined(separator: "\n")) }
        guard let entries = parsed.result?.entries, !entries.isEmpty,
              entries.allSatisfy({ $0.kind == "transaction" }) else {
            throw BookkeepingError.reviewRequired("此入口接收交易片段。包含账户、include 或设置的完整账本，请使用「导入本地账本」。")
        }
        return entries.count
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    }
}
