import CoreGraphics
import XCTest

@testable import tidy

@objcMembers
final class CropSessionTests: XCTestCase {
    /// 默认选框 = 图片文档区 100% 全选（详设 §2.5）
    func testDefaultSelectionCoversWholeImage() {
        // image 400×300，scale 1.5 → 文档区 (0,0,600,450)
        let docRect = CGRect(x: 0, y: 0, width: 600, height: 450)
        let session = CropSession(imageRectInView: docRect)
        XCTAssertEqual(session.rectInView, docRect)
        let pixel = session.pixelRect(scale: 1.5, imageSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(pixel, CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    /// 缩小显示（scale < 1）：全选换算回完整像素
    func testPixelRectFitScaleDown() {
        // image 1000×500，scale 0.2 → 文档区 (0,0,200,100)
        let session = CropSession(imageRectInView: CGRect(x: 0, y: 0, width: 200, height: 100))
        let pixel = session.pixelRect(scale: 0.2, imageSize: CGSize(width: 1000, height: 500))
        XCTAssertEqual(pixel, CGRect(x: 0, y: 0, width: 1000, height: 500))
    }

    /// 放大显示（scale > 1）：全选换算回完整像素
    func testPixelRectFitScaleUp() {
        // image 100×200，scale 2 → 文档区 (0,0,200,400)
        let session = CropSession(imageRectInView: CGRect(x: 0, y: 0, width: 200, height: 400))
        let pixel = session.pixelRect(scale: 2, imageSize: CGSize(width: 100, height: 200))
        XCTAssertEqual(pixel, CGRect(x: 0, y: 0, width: 100, height: 200))
    }

    /// 非整数 scale + 取整规则
    func testPixelRectNonIntegerScale() {
        // image 300×200，scale 2/3 → 文档区 200×133.3
        var session = CropSession(imageRectInView: CGRect(x: 0, y: 0, width: 200, height: 400.0 / 3.0))
        session.rectInView = CGRect(x: 20, y: 30, width: 100, height: 50)
        let pixel = session.pixelRect(scale: 2.0 / 3.0, imageSize: CGSize(width: 300, height: 200))
        // 取整规则（floor origin / ceil max）±1px 浮点噪声
        XCTAssertEqual(pixel.minX, 30, accuracy: 1)
        XCTAssertEqual(pixel.minY, 45, accuracy: 1)
        XCTAssertEqual(pixel.width, 150, accuracy: 1)
        XCTAssertEqual(pixel.height, 75, accuracy: 1)
    }

    /// 选区越界 clamp 到图像边界
    func testPixelRectClampsToImageBounds() {
        // image 100×100，scale 1 → 文档区 (0,0,100,100)
        var session = CropSession(imageRectInView: CGRect(x: 0, y: 0, width: 100, height: 100))
        session.rectInView = CGRect(x: 50, y: 50, width: 200, height: 200)
        let pixel = session.pixelRect(scale: 1, imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(pixel, CGRect(x: 50, y: 50, width: 50, height: 50))
    }

    /// 选区完全在图外 → 空
    func testPixelRectOutsideImage() {
        // image 100×200，scale 2 → 文档区 (0,0,200,400)；选区在文档区右外侧
        var session = CropSession(imageRectInView: CGRect(x: 0, y: 0, width: 200, height: 400))
        session.rectInView = CGRect(x: 250, y: 0, width: 100, height: 100)
        let pixel = session.pixelRect(scale: 2, imageSize: CGSize(width: 100, height: 200))
        XCTAssertEqual(pixel, .zero)
    }

    /// EXIF 旋转图：文档/像素尺寸均为转正后尺寸（200×100 横图），换算按转正后尺寸进行
    func testPixelRectRotatedImageDisplaySize() {
        // 转正后 imageSize 200×100，scale 2 → 文档区 (0,0,400,200)
        var session = CropSession(imageRectInView: CGRect(x: 0, y: 0, width: 400, height: 200))
        session.rectInView = CGRect(x: 200, y: 0, width: 200, height: 200) // 右半
        let pixel = session.pixelRect(scale: 2, imageSize: CGSize(width: 200, height: 100))
        XCTAssertEqual(pixel, CGRect(x: 100, y: 0, width: 100, height: 100))
    }

    /// 10×10pt 下限
    func testResizeMinimumSize() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rect = CGRect(x: 10, y: 10, width: 50, height: 50)
        let resized = CropSession.resized(rect: rect, anchor: .bottomRight,
                                          to: CGPoint(x: 11, y: 11), in: bounds)
        XCTAssertEqual(resized.width, Constants.minCropSize)
        XCTAssertEqual(resized.height, Constants.minCropSize)
        XCTAssertEqual(resized.origin, rect.origin)
    }

    /// 拖出图片边界自动 clamp
    func testResizeClampedToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rect = CGRect(x: 10, y: 10, width: 50, height: 50)
        let resized = CropSession.resized(rect: rect, anchor: .bottomRight,
                                          to: CGPoint(x: 500, y: -50), in: bounds)
        XCTAssertEqual(resized.maxX, bounds.maxX)
        XCTAssertEqual(resized.maxY, rect.minY + Constants.minCropSize, "bottomRight 手柄只动右/下两边，下边受最小尺寸约束")
    }

    /// 角/边手柄只动对应边
    func testResizeAnchors() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let rect = CGRect(x: 50, y: 50, width: 100, height: 100)
        let left = CropSession.resized(rect: rect, anchor: .left, to: CGPoint(x: 20, y: 999), in: bounds)
        XCTAssertEqual(left, CGRect(x: 20, y: 50, width: 130, height: 100))
        let topLeft = CropSession.resized(rect: rect, anchor: .topLeft, to: CGPoint(x: 30, y: 40), in: bounds)
        XCTAssertEqual(topLeft, CGRect(x: 30, y: 40, width: 120, height: 110))
    }

    /// 整体移动 clamp 在显示区域内、尺寸不变
    func testMoveClampedToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rect = CGRect(x: 10, y: 10, width: 40, height: 40)
        XCTAssertEqual(
            CropSession.moved(rect: rect, by: CGSize(width: -50, height: 0), in: bounds).origin,
            CGPoint(x: 0, y: 10)
        )
        XCTAssertEqual(
            CropSession.moved(rect: rect, by: CGSize(width: 0, height: 200), in: bounds).origin,
            CGPoint(x: 10, y: 60)
        )
    }

    /// 缩放/窗口尺寸变化时选区按比例映射：保持相对图片文档区的位置与比例（详设 §2.5）
    func testRemappedKeepsRelativeGeometry() {
        let oldRect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let newRect = CGRect(x: 0, y: 0, width: 200, height: 150) // 缩小一半
        let selection = CGRect(x: 100, y: 75, width: 200, height: 150) // 文档区中央 50%
        let mapped = CropSession.remapped(rect: selection, from: oldRect, to: newRect)
        XCTAssertEqual(mapped, CGRect(x: 50, y: 37.5, width: 100, height: 75))
    }

    /// 100% 全选映射后仍是 100% 全选
    func testRemappedFullSelectionStaysFull() {
        let oldRect = CGRect(x: 0, y: 0, width: 600, height: 450)
        let newRect = CGRect(x: 0, y: 0, width: 300, height: 225)
        XCTAssertEqual(CropSession.remapped(rect: oldRect, from: oldRect, to: newRect), newRect)
    }

    /// 旧显示区为空（异常态）时选区原样返回
    func testRemappedWithEmptyOldRect() {
        let rect = CGRect(x: 10, y: 10, width: 50, height: 50)
        XCTAssertEqual(CropSession.remapped(rect: rect, from: .zero, to: CGRect(x: 0, y: 0, width: 100, height: 100)), rect)
    }
}
