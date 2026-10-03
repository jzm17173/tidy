import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import tidy

@objcMembers
final class CropExporterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestImageFactory.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: suggestURL 命名（详设 §2.5）

    func testSuggestURLSequence() throws {
        let source = tempDir.appendingPathComponent("photo_001.jpg")
        try TestImageFactory.write(TestImageFactory.makeImage(width: 8, height: 8), to: source, type: .jpeg)

        let first = CropExporter.suggestURL(for: source, in: tempDir)
        XCTAssertEqual(first.lastPathComponent, "photo_001 (2).jpg")

        try Data().write(to: first)
        let second = CropExporter.suggestURL(for: source, in: tempDir)
        XCTAssertEqual(second.lastPathComponent, "photo_001 (3).jpg")

        // 跳过已存在：删掉 (2) 后，(3) 仍被占用 → 仍给 (2)
        try FileManager.default.removeItem(at: first)
        let third = CropExporter.suggestURL(for: source, in: tempDir)
        XCTAssertEqual(third.lastPathComponent, "photo_001 (2).jpg")
    }

    func testSuggestURLExtensionOverride() throws {
        let source = tempDir.appendingPathComponent("photo.webp")
        try Data("x".utf8).write(to: source)
        let suggested = CropExporter.suggestURL(for: source, in: tempDir, extension: "png")
        XCTAssertEqual(suggested.lastPathComponent, "photo (2).png")
    }

    // MARK: 动图守卫

    func testAnimatedGIFDetected() throws {
        let gif = tempDir.appendingPathComponent("anim.gif")
        try TestImageFactory.writeGIF(frames: 2, size: CGSize(width: 8, height: 8), to: gif)
        XCTAssertTrue(CropExporter.isAnimatedImage(gif))
    }

    func testStaticImageNotAnimated() throws {
        let png = tempDir.appendingPathComponent("static.png")
        try TestImageFactory.write(TestImageFactory.makeImage(width: 8, height: 8), to: png, type: .png)
        XCTAssertFalse(CropExporter.isAnimatedImage(png))

        let singleGIF = tempDir.appendingPathComponent("single.gif")
        try TestImageFactory.writeGIF(frames: 1, size: CGSize(width: 8, height: 8), to: singleGIF)
        XCTAssertFalse(CropExporter.isAnimatedImage(singleGIF))
    }

    // MARK: EXIF 方向：正向化后再裁剪

    func testExportAppliesEXIFOrientation() throws {
        // 存储 100×200，orientation=6（显示为 200×100，逆时针转正）
        // 存储像素左半红右半蓝；orientation 6 转正后：视觉顶部 = 存储左列（红），视觉底部 = 存储右列（蓝）
        let source = tempDir.appendingPathComponent("oriented.jpg")
        try TestImageFactory.write(
            TestImageFactory.makeImage(width: 100, height: 200, splitColor: true),
            to: source, type: .jpeg, orientation: 6
        )
        let full = try CropExporter.export(source: source, pixelRect: CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(full.width, 200)
        XCTAssertEqual(full.height, 100)
        let top = TestImageFactory.pixel(full, x: 100, y: 10)
        let bottom = TestImageFactory.pixel(full, x: 100, y: 90)
        XCTAssertGreaterThan(top.r, 200, "顶部应偏红，实际 r=\(top.r) g=\(top.g) b=\(top.b)")
        XCTAssertGreaterThan(bottom.b, 200, "底部应偏蓝，实际 r=\(bottom.r) g=\(bottom.g) b=\(bottom.b)")
    }

    func testExportOrientation3() throws {
        // orientation=3：旋转 180°，存储左半红 → 视觉右半红
        let source = tempDir.appendingPathComponent("rot180.jpg")
        try TestImageFactory.write(
            TestImageFactory.makeImage(width: 100, height: 50, splitColor: true),
            to: source, type: .jpeg, orientation: 3
        )
        let full = try CropExporter.export(source: source, pixelRect: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(full.width, 100)
        XCTAssertEqual(full.height, 50)
        let left = TestImageFactory.pixel(full, x: 10, y: 25)
        let right = TestImageFactory.pixel(full, x: 90, y: 25)
        XCTAssertGreaterThan(right.r, 200)
        XCTAssertGreaterThan(left.b, 200)
    }

    func testExportPartialCrop() throws {
        let source = tempDir.appendingPathComponent("plain.png")
        try TestImageFactory.write(TestImageFactory.makeImage(width: 100, height: 80), to: source, type: .png)
        let cropped = try CropExporter.export(source: source, pixelRect: CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(cropped.width, 30)
        XCTAssertEqual(cropped.height, 40)
    }

    // MARK: 写盘质量策略

    func testWritePNGLossless() throws {
        let source = tempDir.appendingPathComponent("src.png")
        let image = TestImageFactory.makeImage(width: 20, height: 20, splitColor: true)
        try TestImageFactory.write(image, to: source, type: .png)
        let out = tempDir.appendingPathComponent("out.png")
        try CropExporter.write(image, to: out, type: .png)
        let reloaded = try CropExporter.export(source: out, pixelRect: CGRect(x: 0, y: 0, width: 20, height: 20))
        // PNG 比特级无损：采样四角像素应与原图一致
        XCTAssertEqual(TestImageFactory.pixel(reloaded, x: 5, y: 5).r, 255)
        XCTAssertEqual(TestImageFactory.pixel(reloaded, x: 15, y: 5).b, 255)
    }

    // MARK: macOS 13 WebP 降级 PNG

    func testWebPOutputTypeDegradesToPNGOnMacOS13() throws {
        let webp = tempDir.appendingPathComponent("photo.webp")
        try Data("x".utf8).write(to: webp)
        let type = CropExporter.outputType(for: webp)
        if CropExporter.canEncodeWebP {
            XCTAssertEqual(type, .webP)
        } else {
            XCTAssertEqual(type, .png, "macOS 13 无 WebP 编码器，应降级 PNG")
        }
    }

    func testJPEGOutputTypeUnchanged() throws {
        let jpg = tempDir.appendingPathComponent("photo.jpg")
        try TestImageFactory.write(TestImageFactory.makeImage(width: 8, height: 8), to: jpg, type: .jpeg)
        XCTAssertEqual(CropExporter.outputType(for: jpg), .jpeg)
    }
}
