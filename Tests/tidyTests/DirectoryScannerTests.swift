import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import tidy

@objcMembers
final class DirectoryScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestImageFactory.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        // 权限测试可能留下只读目录，先恢复权限再清理
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeJPEG(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try TestImageFactory.write(TestImageFactory.makeImage(width: 8, height: 8), to: url, type: .jpeg)
        return url
    }

    func testNaturalSort() throws {
        try makeJPEG("photo1.jpg")
        try makeJPEG("photo10.jpg")
        try makeJPEG("photo2.jpg")
        let scanned = try DirectoryScanner.scan(directory: tempDir)
        XCTAssertEqual(scanned.map { $0.lastPathComponent }, ["photo1.jpg", "photo2.jpg", "photo10.jpg"])
    }

    func testWhitelistExcludesRawSvgText() throws {
        try makeJPEG("keep.jpg")
        for name in ["photo.cr2", "icon.svg", "notes.txt"] {
            try Data("dummy".utf8).write(to: tempDir.appendingPathComponent(name))
        }
        let scanned = try DirectoryScanner.scan(directory: tempDir)
        XCTAssertEqual(scanned.map { $0.lastPathComponent }, ["keep.jpg"])
    }

    func testSkipsHiddenFiles() throws {
        try makeJPEG("visible.jpg")
        try makeJPEG(".hidden.jpg")
        let scanned = try DirectoryScanner.scan(directory: tempDir)
        XCTAssertEqual(scanned.map { $0.lastPathComponent }, ["visible.jpg"])
    }

    func testEmptyDirectory() throws {
        XCTAssertEqual(try DirectoryScanner.scan(directory: tempDir), [])
    }

    func testPermissionError() throws {
        let sub = tempDir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sub.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path)
        }
        XCTAssertThrowsError(try DirectoryScanner.scan(directory: sub)) { error in
            XCTAssertTrue(DirectoryScanner.isPermissionError(error), "应为权限类错误，实际: \(error)")
        }
    }

    func testMissingDirectoryThrowsNonPermissionError() {
        let missing = tempDir.appendingPathComponent("no-such-dir")
        XCTAssertThrowsError(try DirectoryScanner.scan(directory: missing)) { error in
            XCTAssertFalse(DirectoryScanner.isPermissionError(error))
        }
    }

    func testIsSupported() throws {
        let jpg = try makeJPEG("a.jpg")
        XCTAssertTrue(DirectoryScanner.isSupported(jpg))
        XCTAssertFalse(DirectoryScanner.isSupported(tempDir.appendingPathComponent("a.cr2")))
        XCTAssertFalse(DirectoryScanner.isSupported(tempDir.appendingPathComponent("a.txt")))
    }
}
