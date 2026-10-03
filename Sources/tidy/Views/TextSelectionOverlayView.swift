import AppKit

/// 划选文本覆盖层（详设 §2.7）：识别文本的字符级命中、划选与高亮（参考 Mac 预览实况文本）。
/// 图片文档视图的子视图（随滚动/缩放移动），坐标为图片文档坐标（相对图片显示区，origin 恒 0）。
/// hitTest 只在文本行内命中：行外点击穿透给文档视图（窗口拖拽不受影响，并由文档视图清除划选）。
final class TextSelectionOverlayView: NSView {
    private(set) var lines: [RecognizedTextLine] = []
    private(set) var selection: TextSelection?
    var onSelectionChange: ((TextSelection?) -> Void)?

    /// 行框缓存（图片文档坐标），update 时重算
    private var lineRects: [CGRect] = []
    private var docSize: CGSize = .zero
    private var dragAnchor: TextPosition?

    override var isFlipped: Bool { true }

    func update(lines: [RecognizedTextLine], docSize: CGSize, selection: TextSelection?) {
        self.lines = lines
        self.docSize = docSize
        self.selection = selection
        lineRects = lines.map { TextRecognizer.docRect(for: $0.boundingBox, in: docSize) }
        needsDisplay = true
    }

    /// 行框外扩 2pt 容差（行间距小也能点中，参考裁剪手柄热区思路）
    private func lineIndex(at point: CGPoint) -> Int? {
        lineRects.indices.first { lineRects[$0].insetBy(dx: -2, dy: -2).contains(point) }
    }

    /// 行内字符插入位：x 落在某字符框中线左侧 → 该字符之前；越过所有字符 → 行尾
    private func charPosition(atX x: CGFloat, in lineIndex: Int) -> Int {
        let line = lines[lineIndex]
        // 字符框不可用（旋转文本等）：退化为整行二选一
        guard line.charBoxes.count == line.text.count, !line.charBoxes.isEmpty else {
            return x > lineRects[lineIndex].midX ? line.text.count : 0
        }
        for (index, box) in line.charBoxes.enumerated() {
            let rect = TextRecognizer.docRect(for: box, in: docSize)
            if x < rect.midX { return index }
        }
        return line.text.count
    }

    /// 命中 → (行, 字符位)；未命中任何行 → nil
    private func hitPosition(at point: CGPoint) -> TextPosition? {
        guard let line = lineIndex(at: point) else { return nil }
        return TextPosition(line: line, char: charPosition(atX: point.x, in: line))
    }

    /// 拖出行框外：取最近行的对应字符位（划到首行之上 → 首行，末行之下 → 末行）
    private func nearestPosition(to point: CGPoint) -> TextPosition? {
        guard let line = lineRects.indices.min(by: {
            distance(from: lineRects[$0], to: point) < distance(from: lineRects[$1], to: point)
        }) else { return nil }
        return TextPosition(line: line, char: charPosition(atX: point.x, in: line))
    }

    private func distance(from rect: CGRect, to point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, !lines.isEmpty, let superview else { return nil }
        let local = convert(point, from: superview)
        return lineIndex(at: local) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let position = hitPosition(at: point) else { return }
        dragAnchor = position
        // 单击落定：选区收缩为空（待拖动扩出）；双击交由系统三次点击等手势不在 v1 范围
        onSelectionChange?(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let caret = hitPosition(at: point) ?? nearestPosition(to: point) else { return }
        let selection = TextSelection(anchor: anchor, caret: caret)
        onSelectionChange?(selection.isEmpty ? nil : selection)
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreaRef.map(removeTrackingArea)
        let area = NSTrackingArea(
            rect: .zero, // .inVisibleRect：跟随 visibleRect 自动更新
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    private var trackingAreaRef: NSTrackingArea?

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (lineIndex(at: point) != nil ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    /// 每行的选中高亮区：选中字符合并为一个矩形（竖向用行框，横向取首末选中字符框的缘）
    private func highlightRect(inLine lineIndex: Int, selection: TextSelection) -> CGRect? {
        guard lineRects.indices.contains(lineIndex) else { return nil }
        let line = lines[lineIndex]
        let lo = lineIndex == selection.start.line ? selection.start.char : 0
        let hi = lineIndex == selection.end.line ? selection.end.char : line.text.count
        guard lo < hi, hi <= line.text.count else { return nil }
        let lineRect = lineRects[lineIndex]
        guard line.charBoxes.count == line.text.count, !line.charBoxes.isEmpty else {
            return lineRect // 无字符框：整行高亮
        }
        let firstRect = TextRecognizer.docRect(for: line.charBoxes[lo], in: docSize)
        let lastRect = TextRecognizer.docRect(for: line.charBoxes[hi - 1], in: docSize)
        return CGRect(
            x: firstRect.minX,
            y: lineRect.minY,
            width: lastRect.maxX - firstRect.minX,
            height: lineRect.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let selection, !selection.isEmpty else { return }
        let accent = NSColor.controlAccentColor
        for lineIndex in selection.start.line...selection.end.line {
            guard let rect = highlightRect(inLine: lineIndex, selection: selection)?.insetBy(dx: -1, dy: -1) else { continue }
            accent.withAlphaComponent(0.28).setFill()
            rect.fill()
            accent.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 0.5
            border.stroke()
        }
    }
}
