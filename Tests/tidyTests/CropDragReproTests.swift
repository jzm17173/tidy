import AppKit
import SwiftUI
import XCTest

@testable import tidy

/// 裁剪拖拽 UI 链路测试：真实 NSWindow + NSHostingView(ContentView)，合成鼠标事件走完整分发。
/// 回归「按下手柄/选区后拖不动」：mouseDown 与 mouseDragged 之间任意一次视图刷新
/// （OCR 完成、Toast 消失等 @Published 变化）触发 updateNSView → update(...)，
/// 不能用 viewModel 的滞后副本（anchor=nil）覆盖 overlay 本地的拖拽锚点。
///
/// 注意（scripts/test-env 的自定义 runner）：嵌套 runloop 不排干 main queue，
/// 所以每个 @MainActor 步骤用独立 runOnMain、步骤间用顶层 pump 驱动异步任务。
@objcMembers
final class CropDragReproTests: XCTestCase {
    private var tempDir: URL!
    private let windowBox = TestBox<NSWindow>()
    private let vmBox = TestBox<GalleryViewModel>()
    private let pointBox = TestBox<(start: NSPoint, end: NSPoint)>()
    private let rectBox = TestBox<CGRect>()

    override func setUpWithError() throws {
        tempDir = try TestImageFactory.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 正常拖拽（按下后无中间刷新）：选区应跟随移动
    func testCropDragMovesSelection() throws {
        try runDragScenario(triggerInterimUpdate: false)
    }

    /// 按下与拖动之间来了一次无关刷新（回归）：拖拽不应被打断
    func testCropDragSurvivesInterimViewUpdate() throws {
        try runDragScenario(triggerInterimUpdate: true)
    }

    private func runDragScenario(triggerInterimUpdate: Bool) throws {
        try makeFixture()
        pump(0.5) // 等 OCR 防抖任务结束，排除夹具自身的中间刷新

        // mouseDown 按在右下角手柄上
        try runOnMain {
            guard let vm = self.vmBox.value, let window = self.windowBox.value else {
                return XCTFail("夹具未就绪")
            }
            guard case .cropping(let session) = vm.mode else { return XCTFail("未进入裁剪态") }
            self.rectBox.value = session.rectInView
            guard let overlay = self.findCropOverlay(in: window.contentView!) else {
                return XCTFail("找不到 CropOverlayView")
            }
            XCTAssertFalse(overlay.isHidden, "裁剪 overlay 应可见")
            // 拖右下角手柄向内收（初始选区 100% 全选，整体移动会被 clamp 回原位，故测手柄缩放）：
            // 视图(flipped)坐标 (-60,-60) = 窗口坐标 (-60,+60)
            let rect = session.rectInView
            let start = overlay.convert(NSPoint(x: rect.maxX, y: rect.maxY), to: nil)
            self.pointBox.value = (start, NSPoint(x: start.x - 60, y: start.y + 60))
            self.send(.leftMouseDown, at: start, window: window)
        }

        if triggerInterimUpdate {
            // 模拟按下后、拖动前到来的一次无关 @Published 刷新
            try runOnMain { self.vmBox.value?.updateTextSelection(nil) }
            pump(0.1)
        }

        try runOnMain {
            guard let window = self.windowBox.value, let points = self.pointBox.value else { return }
            self.send(.leftMouseDragged, at: points.end, window: window)
        }
        pump(0.3) // 让 onChange → viewModel → 刷新 的异步回流跑完
        try runOnMain {
            guard let window = self.windowBox.value, let points = self.pointBox.value else { return }
            self.send(.leftMouseUp, at: points.end, window: window)
        }
        pump(0.2)

        try runOnMain {
            guard let vm = self.vmBox.value else { return }
            guard case .cropping(let session) = vm.mode else { return XCTFail("拖拽后退出裁剪态") }
            let before = self.rectBox.value ?? .zero
            let message = triggerInterimUpdate
                ? "按下与拖动之间的视图刷新不应打断拖拽（锚点被覆盖则拖不动）"
                : "正常拖拽应缩小选区"
            XCTAssertEqual(session.rectInView.width - before.width, -60, accuracy: 1, message)
            XCTAssertEqual(session.rectInView.height - before.height, -60, accuracy: 1, message)
        }
        try runOnMain { self.windowBox.value?.close() }
    }

    // MARK: - 夹具

    /// 真实窗口 + ContentView；打开一张 400×300 图并进入裁剪态
    private func makeFixture() throws {
        let url = tempDir.appendingPathComponent("a.jpg")
        try TestImageFactory.write(TestImageFactory.makeImage(width: 400, height: 300), to: url, type: .jpeg)

        try runOnMain {
            let vm = GalleryViewModel()
            let window = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 480, height: 480),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false
            )
            window.contentView = NSHostingView(rootView: ContentView(viewModel: vm))
            window.orderFront(nil)
            self.vmBox.value = vm
            self.windowBox.value = window
            vm.open([url])
        }
        pump(2.0) // 顶层泵：等两级图片加载完成
        try runOnMain {
            guard let vm = self.vmBox.value else { return XCTFail("夹具未就绪") }
            XCTAssertNotNil(vm.displayState.image, "图片未加载")
            vm.startCropping()
        }
        pump(0.3) // 等进入裁剪态的刷新落地
    }

    @MainActor
    private func findCropOverlay(in view: NSView) -> CropOverlayView? {
        if let overlay = view as? CropOverlayView { return overlay }
        for sub in view.subviews {
            if let found = findCropOverlay(in: sub) { return found }
        }
        return nil
    }

    @MainActor
    private func send(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        // 自定义 runner 里 window.sendEvent 的合成事件路由不可靠（进程未激活），
        // 直接投递给命中视图——路由在真实系统无问题，本测试针对的是 overlay 内部状态机
        guard let overlay = findCropOverlay(in: window.contentView!) else { return }
        switch type {
        case .leftMouseDown: overlay.mouseDown(with: event)
        case .leftMouseDragged: overlay.mouseDragged(with: event)
        case .leftMouseUp: overlay.mouseUp(with: event)
        default: break
        }
    }

    /// 顶层 runloop 泵。此环境（scripts/test-env 的自定义 runner）里 run(mode:before:) 不阻塞、
    /// 每次调用只排干一轮 main queue 就返回，所以按截止时间反复调用（同 runOnMain 的自旋模式）
    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }
}
