import XCTest
@testable import LedgerMobile

/// `PosixStat` replaced `FileManager.attributesOfItem` at call sites that only
/// need type, size, permission bits and modification date. `attributesOfItem`
/// additionally lists and fetches extended attributes, which costs roughly ten
/// times more, so those call sites must not silently change meaning.
final class PosixStatTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PosixStatTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAgreesWithAttributesOfItemForRegularFiles() throws {
        for permissions in [0o600, 0o644, 0o700, 0o755] {
            let url = root.appendingPathComponent("file-\(String(permissions, radix: 8))")
            try Data(repeating: 0x41, count: 1234).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)

            let stat = try PosixStat.at(url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)

            XCTAssertTrue(stat.isRegularFile)
            XCTAssertFalse(stat.isDirectory)
            XCTAssertFalse(stat.isSymbolicLink)
            XCTAssertEqual(stat.size, (attributes[.size] as? NSNumber)?.intValue)
            XCTAssertEqual(stat.isExecutable,
                (((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111) != 0,
                "permission bits must match for \(String(permissions, radix: 8))")
            XCTAssertEqual(stat.modified.timeIntervalSince1970,
                (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1,
                accuracy: 0.001)
        }
    }

    func testAgreesWithAttributesOfItemForDirectories() throws {
        let url = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let stat = try PosixStat.at(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)

        XCTAssertTrue(stat.isDirectory)
        XCTAssertFalse(stat.isRegularFile)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
    }

    func testDetectsSymbolicLinksWithoutFollowingThem() throws {
        let target = root.appendingPathComponent("target")
        try Data("x".utf8).write(to: target)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let stat = try PosixStat.at(link)
        XCTAssertTrue(stat.isSymbolicLink)
        XCTAssertFalse(stat.isRegularFile,
            "lstat must not resolve the link the way attributesOfItem does")
    }

    func testMissingPathThrows() {
        XCTAssertThrowsError(try PosixStat.at(root.appendingPathComponent("absent")))
    }
}
