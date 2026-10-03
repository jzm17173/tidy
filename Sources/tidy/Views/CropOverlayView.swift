import AppKit
import SwiftUI

/// 裁剪覆盖层（详设 §2.5）：8 手柄 + 整体移动 + 遮罩 + 三分线 + 实时像素尺寸。
/// 直接作为图片文档视图的子视图（随滚动/缩放移动），坐标为图片文档坐标。
final class CropOverlayView: NSView {
    var session = CropSession(imageRectInView: .zero)
    var imageRect: CGRect = .zero
    var imageSize: CGSize = .zero
    /// 当前缩放（图片 1px 对应点数），像素尺寸标签换算用
    var scale: CGFloat = 1
    var onChange: ((CropSession) -> Void)?

    private var dragStartPoint: CGPoint = .zero
    private var rectAtDragStart: CGRect = .zero
    /// 悬停命中的手柄 / .move / nil：驱动光标变化与手柄高亮（PRD FR-4 可拖拽区域反馈）
    private var hovered: Handle?
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingAreaRef { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let target = hitHandle(at: point) ?? (session.rectInView.contains(point) ? .move : nil)
        if target != hovered {
            hovered = target
            needsDisplay = true
        }
        updateCursor(for: hovered)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    private func updateCursor(for target: Handle?) {
        switch target {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            NSCursor.crosshair.set()
        case .left, .right:
            NSCursor.resizeLeftRight.set()
        case .top, .bottom:
            NSCursor.resizeUpDown.set()
        case .move:
            (session.anchor == .move ? NSCursor.closedHand : NSCursor.openHand).set()
        case nil:
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let handle = hitHandle(at: point) {
            session.anchor = handle
        } else if session.rectInView.contains(point) {
            session.anchor = .move
        } else {
            // 命中选区外部：无操作，不支持从空白处拖出新框
            session.anchor = nil
        }
        updateCursor(for: session.anchor)
        needsDisplay = true
        dragStartPoint = point
        rectAtDragStart = session.rectInView
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = session.anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        if anchor == .move {
            session.rectInView = CropSession.moved(
                rect: rectAtDragStart,
                by: CGSize(width: point.x - dragStartPoint.x, height: point.y - dragStartPoint.y),
                in: imageRect
            )
        } else {
            session.rectInView = CropSession.resized(
                rect: rectAtDragStart, anchor: anchor, to: point, in: imageRect
            )
        }
        onChange?(session)
    }

    override func mouseUp(with event: NSEvent) {
        session.anchor = nil
        onChange?(session)
        let point = convert(event.locationInWindow, from: nil)
        hovered = hitHandle(at: point) ?? (session.rectInView.contains(point) ? .move : nil)
        updateCursor(for: hovered)
        needsDisplay = true
    }

    private func hitHandle(at point: CGPoint) -> Handle? {
        // 热区只向选区内侧认（外扩 3pt 容差）：100% 全选时手柄贴着窗口边缘，
        // 外侧点击留给窗口缩放，避免想拖窗口却误改选区、或想拖手柄却误拖窗口（PRD FR-4）
        guard session.rectInView.insetBy(dx: -3, dy: -3).contains(point) else { return nil }
        let zone = Constants.handleHotZone
        return handlePositions(of: session.rectInView)
            .first { abs(point.x - $0.1.x) <= zone && abs(point.y - $0.1.y) <= zone }?.0
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = session.rectInView
        guard !r.isEmpty, !r.isNull else { return }

        // 选区外 4 个 0.55 黑 alpha 矩形遮暗
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: r.minY).fill()
        NSRect(x: 0, y: r.maxY, width: bounds.width, height: bounds.height - r.maxY).fill()
        NSRect(x: 0, y: r.minY, width: r.minX, height: r.height).fill()
        NSRect(x: r.maxX, y: r.minY, width: bounds.width - r.maxX, height: r.height).fill()

        // 三分线
        NSColor.white.withAlphaComponent(0.5).setStroke()
        let thirds = NSBezierPath()
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3
            thirds.move(to: CGPoint(x: x, y: r.minY))
            thirds.line(to: CGPoint(x: x, y: r.maxY))
            let y = r.minY + r.height * CGFloat(i) / 3
            thirds.move(to: CGPoint(x: r.minX, y: y))
            thirds.line(to: CGPoint(x: r.maxX, y: y))
        }
        thirds.lineWidth = 0.5
        thirds.stroke()

        // 选区 1.5pt 白边
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1.5
        border.stroke()

        // 8 手柄：悬停/拖动中的手柄用强调色放大高亮，其余白色（PRD FR-4 可拖拽区域反馈）
        for (handle, center) in handlePositions(of: r) {
            let highlighted = handle == hovered || handle == session.anchor
            let handleSize: CGFloat = highlighted ? 18 : 14
            (highlighted ? NSColor.controlAccentColor : NSColor.white).setFill()
            NSRect(x: center.x - handleSize / 2, y: center.y - handleSize / 2,
                   width: handleSize, height: handleSize).fill()
        }

        // 右下角实时像素尺寸
        let pixel = session.pixelRect(scale: scale, imageSize: imageSize)
        let label = "\(Int(pixel.width)) × \(Int(pixel.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6)
        ]
        let size = label.size(withAttributes: attributes)
        let origin = CGPoint(x: r.maxX - size.width - 6, y: r.maxY + 6)
        label.draw(at: origin, withAttributes: attributes)
    }

    private func handlePositions(of r: CGRect) -> [(Handle, CGPoint)] {
        [
            (.topLeft, CGPoint(x: r.minX, y: r.minY)),
            (.top, CGPoint(x: r.midX, y: r.minY)),
            (.topRight, CGPoint(x: r.maxX, y: r.minY)),
            (.left, CGPoint(x: r.minX, y: r.midY)),
            (.right, CGPoint(x: r.maxX, y: r.midY)),
            (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
            (.bottom, CGPoint(x: r.midX, y: r.maxY)),
            (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))
        ]
    }
}
