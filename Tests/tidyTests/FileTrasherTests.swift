import Foundation
import XCTest

@testable import tidy

@objcMembers
final class FileTrasherTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestImageFactory.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try TestImageFactory.write(TestImageFactory.makeImage(width: 8, height: 8), to: url, type: .jpeg)
        return url
    }

    // MARK: FileTrasher 直接行为

    func testTrashExistingFile() throws {
        let file = try makeFile("a.jpg")
        XCTAssertNoThrow(try FileTrasher.trash(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "删除后原路径应不存在")
    }

    func testTrashMissingFileThrowsMissingError() throws {
        let missing = tempDir.appendingPathComponent("gone.jpg")
        XCTAssertThrowsError(try FileTrasher.trash(missing)) { error in
            XCTAssertTrue(FileTrasher.isMissingFileError(error), "应为「文件已不存在」类错误，实际: \(error)")
        }
    }

    // MARK: GalleryViewModel.trashCurrent 三类分支（详设 §2.4 / 时序 3.2）

    @MainActor
    private func makeViewModel(names: [String], index: Int) throws -> (GalleryViewModel, [URL]) {
        let urls = try names.map { try makeFile($0) }
        let vm = GalleryViewModel()
        vm.items = urls.map { GalleryItem(url: $0) }
        vm.index = index
        return (vm, urls)
    }

    /// 成功：移除、跳到下一张、toast 带文件名
    func testTrashSuccessMovesToNext() throws {
        try runOnMain {
            let (vm, urls) = try self.makeViewModel(names: ["1.jpg", "2.jpg", "3.jpg"], index: 1)
            vm.trashCurrent()
            XCTAssertEqual(vm.items.map { $0.url }, [urls[0], urls[2]])
            XCTAssertEqual(vm.index, 1, "应跳到下一张")
            XCTAssertEqual(vm.toast?.message, "已移到废纸篓：2.jpg")
            XCTAssertFalse(FileManager.default.fileExists(atPath: urls[1].path))
        }
    }

    /// 删除最后一张：跳上一张（nextTarget = index-1）
    func testTrashLastMovesToPrevious() throws {
        try runOnMain {
            let (vm, urls) = try self.makeViewModel(names: ["1.jpg", "2.jpg"], index: 1)
            vm.trashCurrent()
            XCTAssertEqual(vm.items.map { $0.url }, [urls[0]])
            XCTAssertEqual(vm.index, 0)
        }
    }

    /// 单图删除：先判空再算，删完进空态（index 归零，items 为空）
    func testTrashSingleItemEmptiesGallery() throws {
        try runOnMain {
            let (vm, _) = try self.makeViewModel(names: ["only.jpg"], index: 0)
            vm.trashCurrent()
            XCTAssertTrue(vm.items.isEmpty)
            XCTAssertEqual(vm.index, 0)
            XCTAssertEqual(vm.toast?.message, "已移到废纸篓：only.jpg")
        }
    }

    /// 文件已不存在：移出图集、跳下一张、toast「文件已不存在」
    func testTrashMissingFileRemovesAndMovesOn() throws {
        try runOnMain {
            let (vm, urls) = try self.makeViewModel(names: ["1.jpg", "2.jpg", "3.jpg"], index: 0)
            try FileManager.default.removeItem(at: urls[0]) // 外部删掉
            vm.trashCurrent()
            XCTAssertEqual(vm.items.map { $0.url }, [urls[1], urls[2]])
            XCTAssertEqual(vm.index, 0, "应停在原来的下一张")
            XCTAssertEqual(vm.toast?.message, "文件已不存在：1.jpg")
        }
    }

    /// 占用/权限失败：文件还在盘上 → 留在当前张，不移出图集
    func testTrashPermissionFailureStays() throws {
        try runOnMain {
            let (vm, urls) = try self.makeViewModel(names: ["1.jpg", "2.jpg"], index: 0)
            // 目录只读 → trashItem 失败（权限类），文件仍在盘上
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: self.tempDir.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.tempDir.path)
            }
            vm.trashCurrent()
            XCTAssertEqual(vm.items.map { $0.url }, urls, "失败时不得移出图集")
            XCTAssertEqual(vm.index, 0, "失败时停留在当前张")
            XCTAssertEqual(vm.toast?.message, "删除失败：1.jpg")
            XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
        }
    }
}
