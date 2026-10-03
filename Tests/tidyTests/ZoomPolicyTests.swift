import CoreGraphics
import XCTest

@testable import tidy

@objcMembers
final class ZoomPolicyTests: XCTestCase {
    private let view = CGSize(width: 1000, height: 1000)

    /// 完整预览：普通大图 = fit
    func testFitModeNormalImageIsFit() {
        let scale = ZoomPolicy.scale(for: .fit, imageSize: CGSize(width: 4000, height: 3000), viewSize: view)
        XCTAssertEqual(scale, 0.25, accuracy: 0.0001)
    }

    /// 完整预览：小图 = 100%，不放大
    func testFitModeSmallImageIs100Percent() {
        let scale = ZoomPolicy.scale(for: .fit, imageSize: CGSize(width: 200, height: 150), viewSize: view)
        XCTAssertEqual(scale, 1, accuracy: 0.0001)
    }

    /// 占满宽度：图片宽度铺满可视区（可超 100%）
    func testFillWidthModeFillsViewWidth() {
        let scale = ZoomPolicy.scale(for: .fillWidth, imageSize: CGSize(width: 300, height: 8000), viewSize: view)
        XCTAssertEqual(scale, 1000.0 / 300.0, accuracy: 0.0001)
    }

    /// 占满宽度：极窄图封顶 maxScale，避免放到失真
    func testFillWidthModeCappedAtMaxScale() {
        let scale = ZoomPolicy.scale(for: .fillWidth, imageSize: CGSize(width: 50, height: 8000), viewSize: view)
        XCTAssertEqual(scale, ZoomPolicy.maxScale)
    }

    /// 巨高图（高/宽 ≥ 阈值）默认占满宽度
    func testDefaultModeTallImageIsFillWidth() {
        XCTAssertEqual(ZoomPolicy.defaultMode(imageSize: CGSize(width: 300, height: 8000)), .fillWidth)
        // 恰好等于阈值也按长截图处理
        let threshold = ZoomPolicy.tallImageAspectRatio
        XCTAssertEqual(ZoomPolicy.defaultMode(imageSize: CGSize(width: 1000, height: 1000 * threshold)), .fillWidth)
    }

    /// 普通图、竖构图照片（高/宽 < 阈值）、巨宽图默认都是完整预览
    func testDefaultModeOthersAreFit() {
        XCTAssertEqual(ZoomPolicy.defaultMode(imageSize: CGSize(width: 4000, height: 3000)), .fit)
        XCTAssertEqual(ZoomPolicy.defaultMode(imageSize: CGSize(width: 1080, height: 2400)), .fit)
        XCTAssertEqual(ZoomPolicy.defaultMode(imageSize: CGSize(width: 10000, height: 200)), .fit)
    }

    /// 尺寸非法（读取失败/未布局）时不崩溃：fit 模式 scale = 1，默认模式 = fit
    func testDegenerateSizes() {
        XCTAssertEqual(ZoomPolicy.scale(for: .fit, imageSize: .zero, viewSize: view), 1)
        XCTAssertEqual(ZoomPolicy.scale(for: .fillWidth, imageSize: CGSize(width: 300, height: 8000), viewSize: .zero), 1)
        XCTAssertEqual(ZoomPolicy.defaultMode(imageSize: .zero), .fit)
    }
}
