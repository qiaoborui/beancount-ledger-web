import Foundation
import XCTest

extension XCTestCase {
    func temporaryWidgetLockDirectory(for suiteName: String) throws -> URL {
        // Portable tests exercise the real file lock without App Group entitlements.
        // Stores sharing a suite also share its isolated lock directory.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return directory
    }
}
