import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif

/// A file the user attached to an Agent conversation, such as a statement to
/// reconcile. It is copied into `runtime/agent-attachments/<conversation>/`,
/// outside every generation, so it never enters a commit, a backup or Git
/// sync. PDFs and images also get a text file of what PDFKit or on-device
/// OCR read from them; the native core parses CSV and Excel itself.
struct LedgerAgentAttachment: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case table, pdf, image, text }

    /// The model's name for it: a1, a2, …
    let id: String
    let name: String
    let kind: Kind
    let bytes: Int
    /// File names inside the conversation's attachment directory.
    let fileName: String
    var textFileName: String? = nil
    var imageFileName: String? = nil
    var pages: Int? = nil
    /// What the device read out of a PDF or an image, in characters; nil for
    /// tables, which the core parses.
    var recognizedCharacters: Int? = nil

    /// The payload one turn sends for this file.
    struct Payload: Encodable, Equatable, Sendable {
        let id: String
        let name: String
        let path: String
        var textPath: String? = nil
        var imagePath: String? = nil
        var pages: Int? = nil
        var new = false
    }

    func payload(in directory: URL, isNew: Bool) -> Payload {
        Payload(id: id, name: name, path: directory.appendingPathComponent(fileName).path,
                textPath: textFileName.map { directory.appendingPathComponent($0).path },
                imagePath: imageFileName.map { directory.appendingPathComponent($0).path },
                pages: pages, new: isNew)
    }

    var symbol: String {
        switch kind {
        case .table: "tablecells"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .text: "doc.plaintext"
        }
    }

    /// One line under the file name: its size and what was read from it.
    var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        switch kind {
        case .pdf:
            let pageText = pages.map { String(localized: "\($0) 页") } ?? ""
            return [size, pageText, recognizedCharacters == 0 ? String(localized: "没有读出文字") : ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .image:
            return recognizedCharacters == 0 ? size + " · " + String(localized: "没有识别出文字") : size
        case .table, .text:
            return size
        }
    }
}

enum LedgerAgentAttachmentError: LocalizedError, Equatable {
    case unsupported(String)
    case tooLarge
    case tooMany
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case let .unsupported(name): String(localized: "「\(name)」的格式不支持。可以上传 CSV、Excel、PDF 或图片。")
        case .tooLarge: String(localized: "文件超过 25 MB，请拆小一点再上传。")
        case .tooMany: String(localized: "一个对话最多 \(LedgerAgentAttachments.maximumCount) 个附件，可以开一个新对话。")
        case let .unreadable(reason): String(localized: "读取附件失败：") + reason
        }
    }
}

/// Copies picked files into a conversation's attachment directory and reads
/// the text out of PDFs and images. Everything runs on the device.
enum LedgerAgentAttachments {
    static let maximumCount = 12
    static let maximumBytes = 25 * 1024 * 1024
    /// Pages of a scanned PDF that get OCR; the text of a text PDF is read
    /// from every page up to `maximumTextPages`.
    static let maximumOCRPages = 20
    static let maximumTextPages = 200
    /// Long side of the copy a vision model sees.
    static let imagePixels = 2048

    static let tableExtensions: Set<String> = ["csv", "tsv", "xlsx", "xlsm", "xls", "html", "htm"]
    static let textExtensions: Set<String> = ["txt"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff"]

    /// The types the file picker offers.
    static var pickerTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText, .pdf, .image, .spreadsheet]
        for ext in ["xlsx", "xls", "xlsm"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    static func kind(of name: String) -> LedgerAgentAttachment.Kind? {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if tableExtensions.contains(ext) { return .table }
        if textExtensions.contains(ext) { return .text }
        return nil
    }

    /// The id after the highest one in use, so a removed file's id is never
    /// given to another.
    static func nextID(after existing: [LedgerAgentAttachment]) -> String {
        let highest = existing.compactMap { Int($0.id.dropFirst()) }.max() ?? 0
        return "a\(highest + 1)"
    }

    /// A file name safe to keep: no directories, no leading dots, bounded.
    static func storedName(id: String, original: String) -> String {
        let base = (original as NSString).lastPathComponent
        let cleaned = base.unicodeScalars.map { scalar -> Character in
            CharacterSet(charactersIn: "/\\:\0").contains(scalar) ? "_" : Character(scalar)
        }
        var name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        if name.isEmpty { name = "file" }
        if name.count > 80 {
            let ext = (name as NSString).pathExtension
            name = String(name.prefix(70)) + (ext.isEmpty ? "" : "." + ext)
        }
        return id + "-" + name
    }

    /// Copies a file the user picked. The source may be security-scoped.
    static func importFile(at source: URL, id: String, into directory: URL) async throws -> LedgerAgentAttachment {
        let name = source.lastPathComponent
        guard let kind = kind(of: name) else { throw LedgerAgentAttachmentError.unsupported(name) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumBytes else { throw LedgerAgentAttachmentError.tooLarge }
            data = try Data(contentsOf: source)
        } catch let error as LedgerAgentAttachmentError {
            throw error
        } catch {
            throw LedgerAgentAttachmentError.unreadable(error.localizedDescription)
        }
        return try await store(data, name: name, kind: kind, id: id, into: directory)
    }

    /// Keeps image bytes from the photo library.
    static func importImage(_ data: Data, name: String, id: String, into directory: URL) async throws -> LedgerAgentAttachment {
        try await store(data, name: name, kind: .image, id: id, into: directory)
    }

    static func store(_ data: Data, name: String, kind: LedgerAgentAttachment.Kind, id: String,
                      into directory: URL) async throws -> LedgerAgentAttachment {
        guard data.count <= maximumBytes else { throw LedgerAgentAttachmentError.tooLarge }
        return try await Task.detached(priority: .userInitiated) {
            let fileName = storedName(id: id, original: name)
            let file = directory.appendingPathComponent(fileName)
            do {
                try data.write(to: file, options: .atomic)
            } catch {
                throw LedgerAgentAttachmentError.unreadable(error.localizedDescription)
            }
            var attachment = LedgerAgentAttachment(id: id, name: name, kind: kind, bytes: data.count, fileName: fileName)
            switch kind {
            case .pdf:
                let (text, pages) = pdfText(file)
                attachment.pages = pages
                attachment.recognizedCharacters = text.count
                attachment.textFileName = try writeText(text, besides: fileName, in: directory)
            case .image:
                if let image = downscaledImage(data) {
                    let imageName = fileName + ".preview.jpg"
                    try? image.jpeg.write(to: directory.appendingPathComponent(imageName), options: .atomic)
                    attachment.imageFileName = imageName
                    let text = recognizeText(in: image.cgImage)
                    attachment.recognizedCharacters = text.count
                    attachment.textFileName = try writeText(text, besides: fileName, in: directory)
                } else {
                    attachment.recognizedCharacters = 0
                }
            case .table, .text:
                break
            }
            return attachment
        }.value
    }

    private static func writeText(_ text: String, besides fileName: String, in directory: URL) throws -> String {
        let textName = fileName + ".txt"
        try Data(text.utf8).write(to: directory.appendingPathComponent(textName), options: .atomic)
        return textName
    }

    // MARK: PDF

    /// The text of a PDF, page by page. Pages without a text layer, as in a
    /// scanned statement, are rendered and read with OCR.
    static func pdfText(_ file: URL) -> (text: String, pages: Int) {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: file) else { return ("", 0) }
        let count = document.pageCount
        var parts: [String] = []
        var ocrPages = 0
        for index in 0..<min(count, maximumTextPages) {
            guard let page = document.page(at: index) else { continue }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count < 20, ocrPages < maximumOCRPages, let image = render(page) {
                ocrPages += 1
                text = recognizeText(in: image)
            }
            if !text.isEmpty { parts.append(String(localized: "—— 第 \(index + 1) 页 ——") + "\n" + text) }
        }
        return (parts.joined(separator: "\n\n"), count)
        #else
        return ("", 0)
        #endif
    }

    #if canImport(PDFKit)
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2.5, 2400 / max(bounds.width, bounds.height))
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
    #endif

    // MARK: Images

    struct ScaledImage {
        let cgImage: CGImage
        let jpeg: Data
    }

    /// A JPEG no longer than `imagePixels` on its long side, oriented upright.
    static func downscaledImage(_ data: Data) -> ScaledImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: imagePixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ScaledImage(cgImage: image, jpeg: output as Data)
    }

    /// Text in an image, one visual line per line. Pieces on the same line,
    /// such as a merchant and its amount, are joined with a tab so a table
    /// keeps its rows.
    static func recognizeText(in image: CGImage) -> String {
        #if canImport(Vision)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        let pieces: [OCRPiece] = (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return OCRPiece(text: text, minX: box.minX, midY: box.midY, height: box.height)
        }
        return lines(from: pieces)
        #else
        return ""
        #endif
    }

    struct OCRPiece: Equatable, Sendable {
        let text: String
        let minX: CGFloat
        /// Vision's normalized coordinates: 0 at the bottom.
        let midY: CGFloat
        let height: CGFloat
    }

    /// Groups recognized pieces into lines, top to bottom and left to right.
    static func lines(from pieces: [OCRPiece]) -> String {
        let sorted = pieces.sorted { $0.midY > $1.midY }
        var rows: [[OCRPiece]] = []
        for piece in sorted {
            if let last = rows.last, let anchor = last.first,
               abs(anchor.midY - piece.midY) < max(anchor.height, piece.height) * 0.5 {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { row in row.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: "\t") }
            .joined(separator: "\n")
    }
}
