import Foundation
import XCTest
@testable import FFFKit

final class HomeDirectoryScanningTests: XCTestCase {
    func testExplicitlyEnabledHomeDirectoryCanStart() async throws {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory
            .appendingPathComponent("FFFKitHomeScanTests-\(UUID().uuidString)")
        let home = fileManager.homeDirectoryForCurrentUser
        let storage = parent.appendingPathComponent("Storage", isDirectory: true)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: parent) }

        let denied = FFFIndex(
            rootURL: home,
            storageURL: storage.appendingPathComponent("Denied"),
            enableContentIndexing: false,
            watch: false
        )
        do {
            try await denied.start()
            XCTFail("FFF unexpectedly allowed a home-directory scan without opt-in")
        } catch FFFIndexError.message(let message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("FFF returned an unexpected error: \(error)")
        }

        let allowed = FFFIndex(
            rootURL: home,
            storageURL: storage.appendingPathComponent("Allowed"),
            enableContentIndexing: false,
            watch: false,
            enableHomeDirectoryScanning: true
        )
        try await allowed.start()
        _ = try await allowed.progress()
    }
}
