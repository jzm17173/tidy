import Foundation
import XCTest

@testable import tidy

/// GalleryViewModel 行为：切换跳过失效项（详设 §2.2 切换流程）与裁剪入口守卫（详设 §2.5）
@objcMembers
final class GalleryViewModelTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestImageFactory.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try TestImageFactory.write(TestImageFactory.makeImage(width: 8, height: 8), to: url, type: .jpeg)
        return url
    }

    /// 图集 = 文件列表 + 当前下标（不做磁盘校验，失效项交给 move 的懒校验）
    @MainActor
    private func makeViewModel(_ urls: [URL], index: Int) -> GalleryViewModel {
        let vm = GalleryViewModel()
        vm.items = urls.map { GalleryItem(url: $0) }
        vm.index = index
        return vm
    }

    // MARK: 切换：next() / previous()（详设 §2.2）

    /// 已删项在当前张之前：→ 必须回绕到下一张有效图，而不是原地停在当前张（review 缺陷 1）
    func testNextSkipsDeletedItemBeforeCurrent() throws {
        try runOnMain {
            let urls = try ["1.jpg", "2.jpg", "3.jpg"].map { try self.makeFile($0) }
            try FileManager.default.removeItem(at: urls[0]) // 外部删掉第一张
            let vm = self.makeViewModel(urls, index: 2) // 停在最后一张
            vm.next()
            XCTAssertEqual(vm.items.map { $0.url }, [urls[1], urls[2]], "失效项应立即移出图集")
            XCTAssertEqual(vm.currentItem?.url, urls[1], "应命中 2.jpg，而不是停在 3.jpg")
            XCTAssertEqual(vm.index, 0, "落点是 2.jpg 的新下标")
        }
    }

    /// previous() 对称场景：已删项在当前张之前，← 走到的是有效图
    func testPreviousSkipsDeletedItemBeforeCurrent() throws {
        try runOnMain {
            let urls = try ["1.jpg", "2.jpg", "3.jpg"].map { try self.makeFile($0) }
            try FileManager.default.removeItem(at: urls[1]) // 删掉中间那张
            let vm = self.makeViewModel(urls, index: 2)
            vm.previous()
            XCTAssertEqual(vm.items.map { $0.url }, [urls[0], urls[2]])
            XCTAssertEqual(vm.currentItem?.url, urls[0], "应命中 1.jpg（2.jpg 已失效）")
            XCTAssertEqual(vm.index, 0)
        }
    }

    /// 连续失效过半：探测预算不得随图集收缩而提前耗尽，回绕一轮内应命中唯一有效项
    func testNextWrapsPastDeletedRunToNextValid() throws {
        try runOnMain {
            let urls = try ["1.jpg", "2.jpg", "3.jpg", "4.jpg", "5.jpg", "6.jpg"].map { try self.makeFile($0) }
            for i in [0, 1, 2, 3, 5] { try FileManager.default.removeItem(at: urls[i]) } // 只剩 5.jpg
            let vm = self.makeViewModel(urls, index: 5) // 当前 6.jpg（已失效）
            vm.next()
            XCTAssertEqual(vm.currentItem?.url, urls[4], "回绕后应命中唯一有效项 5.jpg，而不是停在无效的 6.jpg")
            XCTAssertEqual(vm.index, 0)
            XCTAssertFalse(vm.items.contains { $0.url == urls[0] }, "探测过的失效项应立即移出图集（懒校验）")
        }
    }

    /// 无失效项时的首尾循环基准（原实现无 next/previous 测试）
    func testNextPreviousCycleAtEdges() throws {
        try runOnMain {
            let urls = try ["1.jpg", "2.jpg", "3.jpg"].map { try self.makeFile($0) }
            let vm = self.makeViewModel(urls, index: 2)
            vm.next()
            XCTAssertEqual(vm.index, 0, "最后一张 → 回绕到第一张")
            vm.previous()
            XCTAssertEqual(vm.index, 2, "第一张 ← 回绕到最后一张")
        }
    }

    /// 全部失效 → 空态页（items 清空、index 归零）
    func testNextAllDeletedEmptiesGallery() throws {
        try runOnMain {
            let urls = try ["1.jpg", "2.jpg"].map { try self.makeFile($0) }
            for url in urls { try FileManager.default.removeItem(at: url) }
            let vm = self.makeViewModel(urls, index: 0)
            vm.next()
            XCTAssertTrue(vm.items.isEmpty)
            XCTAssertEqual(vm.index, 0)
        }
    }

    /// 裁剪态下不得切图（方向键用于微调选区，详设 §2.6 键盘路由）
    func testMoveIgnoredInCroppingMode() throws {
        try runOnMain {
            let urls = try ["1.jpg", "2.jpg"].map { try self.makeFile($0) }
            let vm = self.makeViewModel(urls, index: 0)
            vm.mode = .cropping(CropSession(imageRectInView: CGRect(x: 0, y: 0, width: 8, height: 8)))
            vm.next()
            XCTAssertEqual(vm.index, 0)
            XCTAssertEqual(vm.items.map { $0.url }, urls)
        }
    }

    // MARK: 裁剪入口守卫（详设 §2.5）

    /// 白名单外格式（RAW/SVG）：入口判据为假、C 不得进入裁剪
    func testCropEntryBlockedForUnsupportedFormat() throws {
        try runOnMain {
            let svg = self.tempDir.appendingPathComponent("vector.svg")
            try "<svg/>".write(to: svg, atomically: true, encoding: .utf8)
            let vm = GalleryViewModel()
            vm.open([svg])
            XCTAssertEqual(vm.items.count, 1)
            XCTAssertEqual(vm.currentItem?.isSupported, false, "白名单外格式仍留在图集内（显示错误占位页）")
            XCTAssertFalse(vm.canStartCropping, "不支持格式的裁剪按钮应置灰")
            vm.startCropping()
            XCTAssertEqual(vm.mode, .viewing, "C 不得进入裁剪")
        }
    }

    /// 空图集：不得进入裁剪
    func testCropEntryBlockedWithoutItem() throws {
        try runOnMain {
            let vm = GalleryViewModel()
            XCTAssertFalse(vm.canStartCropping)
            vm.startCropping()
            XCTAssertEqual(vm.mode, .viewing)
        }
    }

    /// 两级加载未就绪（image 为空）：入口置灰、C 不得进入
    func testCropEntryBlockedWhileImageNotReady() throws {
        try runOnMain {
            let url = try self.makeFile("ready.jpg")
            let vm = GalleryViewModel()
            vm.open([url])
            XCTAssertNotNil(vm.originalImageSize, "原始尺寸同步就绪（裁剪几何基准）")
            XCTAssertNil(vm.displayState.image, "两级加载尚未产出图像")
            XCTAssertFalse(vm.canStartCropping, "图像未就绪时入口应置灰")
            vm.startCropping()
            XCTAssertEqual(vm.mode, .viewing)
        }
    }

    /// 动图（GIF）：入口置灰 + toast（PRD FR-4 范围）
    func testCropEntryBlockedForAnimatedGIF() throws {
        try runOnMain {
            let gif = self.tempDir.appendingPathComponent("anim.gif")
            try TestImageFactory.writeGIF(frames: 2, size: CGSize(width: 16, height: 16), to: gif)
            let vm = GalleryViewModel()
            vm.open([gif])
            XCTAssertFalse(vm.canStartCropping, "动图的裁剪按钮应置灰")
            vm.startCropping()
            XCTAssertEqual(vm.mode, .viewing)
            XCTAssertEqual(vm.toast?.message, "动图暂不支持裁剪")
        }
    }

    // MARK: 裁剪入口：解码错误态（review 缺陷 2）

    /// 构造前提自检：maxPixels = 0 时缩略图成功、全图抛错——「缩略图成功、全图解不出」的可复现样本
    func testZeroPixelLimitReproducesThumbnailOnlyState() throws {
        let url = try makeFile("thumb-only.jpg")
        let loader = ImageLoader(maxPixels: 0)
        runAsync {
            let thumb = await loader.thumbnail(for: url, maxPixel: 512)
            XCTAssertNotNil(thumb, "缩略图路径应成功（错误态用例的构造前提）")
            do {
                _ = try await loader.fullImage(for: url)
                XCTFail("全图路径应抛错（错误态用例的构造前提）")
            } catch {}
        }
    }

    /// 缩略图成功、全图解码失败：丢弃缩略图 + 错误占位页，C 不得进入裁剪
    func testCropEntryBlockedWhenFullDecodeFails() throws {
        let url = try makeFile("broken-full.jpg")
        // maxPixels = 0 → 降采样长边换算为 0 → 全图路径必失败，构造「缩略图成功、全图解不出」
        let loader = ImageLoader(maxPixels: 0)
        let box = TestBox<GalleryViewModel>()
        runAsync {
            await MainActor.run {
                let vm = GalleryViewModel(loader: loader)
                vm.open([url])
                box.value = vm
            }
            await waitUntil {
                await MainActor.run { () -> Bool in
                    guard let vm = box.value else { return false }
                    return vm.displayState.error != nil
                }
            }
            let hasError = await MainActor.run { () -> Bool in
                guard let vm = box.value else { return false }
                return vm.displayState.error != nil
            }
            XCTAssertTrue(hasError, "全图路径失败必须进入错误态")
            let imageNil = await MainActor.run { () -> Bool in
                guard let vm = box.value else { return false }
                return vm.displayState.image == nil
            }
            XCTAssertTrue(imageNil, "全图失败后不得残留缩略图（image 非空 ⇔ 可显示）")
            let croppable = await MainActor.run { () -> Bool in
                guard let vm = box.value else { return true }
                return vm.canStartCropping
            }
            XCTAssertFalse(croppable, "错误态下裁剪入口应置灰")
            await MainActor.run {
                if let vm = box.value { vm.startCropping() }
            }
            let isViewing = await MainActor.run { () -> Bool in
                guard let vm = box.value else { return false }
                return vm.mode == .viewing
            }
            XCTAssertTrue(isViewing, "错误态下 C 不得进入裁剪")
        }
    }

    /// 正常路径对照：图像就绪且非动图时入口可用、C 能进入裁剪
    func testCropEntryAllowedWhenImageReady() throws {
        let url = try makeFile("ready-full.jpg")
        let box = TestBox<GalleryViewModel>()
        runAsync {
            await MainActor.run {
                let vm = GalleryViewModel()
                vm.open([url])
                box.value = vm
            }
            await waitUntil {
                await MainActor.run { () -> Bool in
                    guard let vm = box.value else { return false }
                    return vm.displayState.image != nil
                }
            }
            let croppable = await MainActor.run { () -> Bool in
                guard let vm = box.value else { return false }
                return vm.canStartCropping
            }
            XCTAssertTrue(croppable, "图像就绪且非动图时应可进入裁剪")
            await MainActor.run {
                if let vm = box.value { vm.startCropping() }
            }
            let isCropping = await MainActor.run { () -> Bool in
                guard let vm = box.value else { return false }
                if case .cropping = vm.mode { return true }
                return false
            }
            XCTAssertTrue(isCropping, "C 应进入裁剪模式")
        }
    }
}
