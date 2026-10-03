import AppKit
import CoreText
import Foundation
import XCTest

@testable import tidy

/// 文本识别（详设 §2.7）：OCR 管道、坐标换算、复制全部 / 复制划选
@objcMembers
final class TextRecognizerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestImageFactory.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 白底黑字渲染单行文本（CoreText 直接画进 CGContext，y 轴自下而上）
    private func makeTextImage(_ string: String, size: CGSize = CGSize(width: 900, height: 300)) -> CGImage {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        let attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 120, weight: .bold),
            .foregroundColor: NSColor.black
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: 90)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    // MARK: TextRecognizer 纯逻辑

    /// Vision 归一化（左下原点）→ 文档坐标（左上原点）：y 翻转、按文档尺寸缩放
    func testDocRectFlipsAndScales() {
        let box = CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1) // 靠近图片顶部的一行
        let rect = TextRecognizer.docRect(for: box, in: CGSize(width: 1000, height: 500))
        XCTAssertEqual(rect.minX, 100, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 100, accuracy: 0.001, "y = (1 - maxY) × 高 = (1-0.8) × 500")
        XCTAssertEqual(rect.width, 500, accuracy: 0.001)
        XCTAssertEqual(rect.height, 50, accuracy: 0.001)
    }

    /// 复制全部：按行序拼接、行间换行
    func testFullTextJoinsLinesInOrder() {
        let lines = [
            RecognizedTextLine(text: "第一行", boundingBox: .zero),
            RecognizedTextLine(text: "second", boundingBox: .zero)
        ]
        XCTAssertEqual(TextRecognizer.fullText(of: lines), "第一行\nsecond")
        XCTAssertEqual(TextRecognizer.fullText(of: []), "")
    }

    /// 划选取文：首尾行按字符截取、中间行整行、行间换行
    func testSelectedTextTrimsPartialLines() {
        let lines = [
            RecognizedTextLine(text: "one", boundingBox: .zero),
            RecognizedTextLine(text: "two", boundingBox: .zero),
            RecognizedTextLine(text: "three", boundingBox: .zero)
        ]
        // 第 1 行从 'n' 起 → 第 2 行到 'w' 止
        let selection = TextSelection(anchor: TextPosition(line: 0, char: 1), caret: TextPosition(line: 1, char: 2))
        XCTAssertEqual(TextRecognizer.selectedText(from: lines, selection: selection), "ne\ntw")
        // 反向拖选（锚点在后）规范化后同结果
        let reversed = TextSelection(anchor: TextPosition(line: 1, char: 2), caret: TextPosition(line: 0, char: 1))
        XCTAssertEqual(TextRecognizer.selectedText(from: lines, selection: reversed), "ne\ntw")
        // 跨整行：第 1 行尾部 → 第 3 行开头，中间行整行
        let spanning = TextSelection(anchor: TextPosition(line: 0, char: 2), caret: TextPosition(line: 2, char: 1))
        XCTAssertEqual(TextRecognizer.selectedText(from: lines, selection: spanning), "e\ntwo\nt")
        // 单行内单字符
        let single = TextSelection(anchor: TextPosition(line: 2, char: 0), caret: TextPosition(line: 2, char: 1))
        XCTAssertEqual(TextRecognizer.selectedText(from: lines, selection: single), "t")
        // 空选择
        let empty = TextSelection(anchor: TextPosition(line: 0, char: 1), caret: TextPosition(line: 0, char: 1))
        XCTAssertEqual(TextRecognizer.selectedText(from: lines, selection: empty), "")
    }

    // MARK: OCR 冒烟（本机 Vision；本环境无 XCTest 异步基建，用 runAsync 同步驱动）

    /// 渲染文本图 → 识别命中文本，行框为合法归一化坐标，逐字符框与文本一一对应
    func testRecognizeFindsRenderedText() {
        runAsync {
            let lines = await TextRecognizer.recognize(image: self.makeTextImage("HELLO"))
            XCTAssertTrue(lines.contains { $0.text.contains("HELLO") }, "识别结果：\(lines.map { $0.text })")
            for line in lines {
                XCTAssertGreaterThanOrEqual(line.boundingBox.minX, 0)
                XCTAssertLessThanOrEqual(line.boundingBox.maxX, 1)
                XCTAssertGreaterThanOrEqual(line.boundingBox.minY, 0)
                XCTAssertLessThanOrEqual(line.boundingBox.maxY, 1)
                if !line.charBoxes.isEmpty {
                    XCTAssertEqual(line.charBoxes.count, line.text.count, "字符框应与文本一一对应（字符级划选基准）")
                }
            }
        }
    }

    /// 无文本图片 → 空结果（不抛错：识别是增强能力）
    func testRecognizeBlankImageReturnsEmpty() {
        runAsync {
            let lines = await TextRecognizer.recognize(image: TestImageFactory.makeImage(width: 64, height: 64))
            XCTAssertTrue(lines.isEmpty)
        }
    }

    // MARK: ViewModel 集成

    /// 静态图：切图后后台识别完成，textLines 非空（端到端：缩略图 → OCR → 归一化行框）
    func testStaticImagePopulatesTextLines() throws {
        let url = tempDir.appendingPathComponent("text.jpg")
        try TestImageFactory.write(makeTextImage("HELLO"), to: url, type: .jpeg)
        let box = TestBox<GalleryViewModel>()
        runAsync {
            await MainActor.run {
                let vm = GalleryViewModel()
                vm.open([url])
                box.value = vm
            }
            await waitUntil(timeout: 15) {
                await MainActor.run { !(box.value?.textLines.isEmpty ?? true) }
            }
            let found = await MainActor.run { box.value?.textLines.contains { $0.text.contains("HELLO") } ?? false }
            let recognized = await MainActor.run { box.value?.textLines.map { $0.text } ?? [] }
            XCTAssertTrue(found, "识别结果：\(recognized)")
        }
    }

    /// 动图（GIF）：不启动识别，textLines 恒为空（详设 §2.7 范围）
    func testAnimatedImageSkipsTextRecognition() throws {
        let gif = tempDir.appendingPathComponent("anim.gif")
        try TestImageFactory.writeGIF(frames: 2, size: CGSize(width: 16, height: 16), to: gif)
        try runOnMain {
            let vm = GalleryViewModel()
            vm.open([gif])
            XCTAssertTrue(vm.textLines.isEmpty)
            XCTAssertNil(vm.textSelection)
        }
    }

    /// 复制全部：拼接所有行写剪贴板 + toast
    func testCopyAllTextWritesPasteboard() throws {
        try runOnMain {
            let vm = GalleryViewModel()
            vm.textLines = [
                RecognizedTextLine(text: "alpha", boundingBox: .zero),
                RecognizedTextLine(text: "beta", boundingBox: .zero)
            ]
            vm.copyAllText()
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "alpha\nbeta")
            XCTAssertEqual(vm.toast?.message, "已复制全部文本")
        }
    }

    /// 复制划选：只写划选区间内的字符（首尾行按字符截取）
    func testCopySelectedTextWritesOnlySelectedLines() throws {
        try runOnMain {
            let vm = GalleryViewModel()
            vm.textLines = [
                RecognizedTextLine(text: "one", boundingBox: .zero),
                RecognizedTextLine(text: "two", boundingBox: .zero),
                RecognizedTextLine(text: "three", boundingBox: .zero)
            ]
            vm.textSelection = TextSelection(anchor: TextPosition(line: 1, char: 1), caret: TextPosition(line: 2, char: 4))
            vm.copySelectedText()
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "wo\nthre")
        }
    }

    /// 无划选 / 无文本：复制静默不动作（不覆盖剪贴板、无 toast）
    func testCopyWithoutTextOrSelectionIsNoOp() throws {
        try runOnMain {
            let vm = GalleryViewModel()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("keep", forType: .string)
            vm.copyAllText()
            XCTAssertNil(vm.toast)
            vm.textLines = [RecognizedTextLine(text: "one", boundingBox: .zero)]
            vm.copySelectedText() // 无 textSelection
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "keep")
            XCTAssertNil(vm.toast)
        }
    }
}
