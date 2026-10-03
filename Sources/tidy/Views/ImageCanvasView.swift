import AppKit
import SwiftUI

/// 大图渲染走 AppKit 自绘视图，绕开 SwiftUI 大图性能问题（详设 §1）。
/// 两种视图模式（PRD FR-1）：
/// - 完整预览（fitInside）：文档视图恒等于可视区，图片以 CALayer 居中绘制——永不出现滚动条；
/// - 占满宽度：文档视图 = 图片尺寸（宽度铺满），高度超出部分出竖向滚动条。
/// 裁剪 overlay 是文档视图的子视图，选区使用图片文档坐标，视图切换/滚动不影响换算（详设 §2.5）。
struct ImageCanvasView: NSViewRepresentable {
    let image: CGImage?
    let animatedURL: URL?
    /// 当前图集项标识：变化时滚动回文档起点（阅读顺序）
    let imageKey: URL?
    /// 图片显示尺寸 = 原始点尺寸 × scale
    let docSize: CGSize
    /// 完整预览（true）/ 占满宽度（false）
    let fitInside: Bool
    /// 裁剪会话：nil 表示非裁剪态
    let cropSession: CropSession?
    /// 原始图片像素尺寸（EXIF 已正向化）
    let originalSize: CGSize
    let scale: CGFloat
    let onSizeChange: (CGSize) -> Void
    let onCropChange: (CropSession) -> Void
    /// 识别文本行（阅读顺序），空数组 = 无文本/不可识别
    let textLines: [RecognizedTextLine]
    /// 划选中的文本行下标（闭区间）；nil = 无划选
    let textSelection: TextSelection?
    let onTextSelectionChange: (TextSelection?) -> Void

    func makeNSView(context: Context) -> CanvasScrollView {
        let view = CanvasScrollView()
        view.onSizeChange = onSizeChange
        view.onCropChange = onCropChange
        view.onTextSelectionChange = onTextSelectionChange
        return view
    }

    func updateNSView(_ nsView: CanvasScrollView, context: Context) {
        nsView.onSizeChange = onSizeChange
        nsView.onCropChange = onCropChange
        nsView.onTextSelectionChange = onTextSelectionChange
        nsView.update(
            image: image, animatedURL: animatedURL, imageKey: imageKey,
            docSize: docSize, fitInside: fitInside, cropSession: cropSession,
            originalSize: originalSize, scale: scale,
            textLines: textLines, textSelection: textSelection
        )
    }
}

/// 占满宽度模式下，文档小于可视区时居中显示（NSScrollView 默认顶左对齐）
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
    /// 行外点击（穿透 textOverlay 的命中）→ 清除文本划选（详设 §2.7）
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

final class CanvasScrollView: NSScrollView {
    var onSizeChange: ((CGSize) -> Void)?
    var onCropChange: ((CropSession) -> Void)?
    var onTextSelectionChange: ((TextSelection?) -> Void)?

    private let docView = FlippedDocumentView()
    private let imageLayer = CALayer()
    private let animatedImageView = NSImageView()
    private let cropOverlay = CropOverlayView()
    private let textOverlay = TextSelectionOverlayView()
    private var lastImageKey: URL?
    private var lastFitInside = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = false
        contentView = CenteringClipView()

        docView.wantsLayer = true
        imageLayer.contentsGravity = .resize
        docView.layer?.addSublayer(imageLayer)

        animatedImageView.imageScaling = .scaleProportionallyUpOrDown
        animatedImageView.animates = true
        animatedImageView.isHidden = true
        docView.addSubview(animatedImageView)

        cropOverlay.isHidden = true
        docView.addSubview(cropOverlay)

        textOverlay.isHidden = true
        textOverlay.onSelectionChange = { [weak self] range in
            // 与 cropOverlay 同一模式：事件回调派发到主队列（FIFO 保序）
            DispatchQueue.main.async { self?.onTextSelectionChange?(range) }
        }
        docView.addSubview(textOverlay)
        docView.onMouseDown = { [weak self] in
            guard self?.textOverlay.selection != nil else { return }
            DispatchQueue.main.async { self?.onTextSelectionChange?(nil) }
        }

        documentView = docView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        // 可视区域尺寸（供 fit / 占满宽度换算）
        onSizeChange?(contentView.bounds.size)
    }

    func update(
        image: CGImage?,
        animatedURL: URL?,
        imageKey: URL?,
        docSize: CGSize,
        fitInside: Bool,
        cropSession: CropSession?,
        originalSize: CGSize,
        scale: CGFloat,
        textLines: [RecognizedTextLine],
        textSelection: TextSelection?
    ) {
        let isNewImage = imageKey != lastImageKey
        let modeChanged = fitInside != lastFitInside
        // 窗口尺寸变化时保持可视中心稳定（仅占满宽度模式；切图/切模式都回起点）
        var relativeCenter: CGPoint?
        let oldDocSize = docView.frame.size
        if !isNewImage, !modeChanged, !fitInside, oldDocSize.width > 0, oldDocSize.height > 0 {
            let visible = contentView.documentVisibleRect
            relativeCenter = CGPoint(
                x: visible.midX / oldDocSize.width,
                y: visible.midY / oldDocSize.height
            )
        }
        lastImageKey = imageKey
        lastFitInside = fitInside

        // 完整预览：文档恒等于可视区，结构上不可能出现滚动条
        hasVerticalScroller = !fitInside
        hasHorizontalScroller = !fitInside
        if fitInside {
            let visibleSize = contentView.bounds.size
            if visibleSize.width > 0, visibleSize.height > 0, docView.frame.size != visibleSize {
                docView.frame = CGRect(origin: .zero, size: visibleSize)
            }
        } else if docSize.width > 0, docSize.height > 0, docView.frame.size != docSize {
            docView.frame = CGRect(origin: .zero, size: docSize)
        }

        // 图片在文档内的显示区：完整预览居中，占满宽度铺满文档
        let imageFrame: CGRect
        if fitInside {
            let b = docView.bounds
            imageFrame = CGRect(
                x: max(0, (b.width - docSize.width) / 2),
                y: max(0, (b.height - docSize.height) / 2),
                width: docSize.width,
                height: docSize.height
            )
        } else {
            imageFrame = docView.bounds
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = imageFrame
        CATransaction.commit()
        animatedImageView.frame = imageFrame
        cropOverlay.frame = imageFrame
        textOverlay.frame = imageFrame

        // 划选文本 overlay：裁剪态 / 无识别文本时隐藏（裁剪手柄优先，详设 §2.7）
        if cropSession == nil, !textLines.isEmpty {
            textOverlay.isHidden = false
            textOverlay.update(lines: textLines, docSize: imageFrame.size, selection: textSelection)
        } else {
            textOverlay.isHidden = true
        }

        if let animatedURL {
            animatedImageView.image = NSImage(contentsOf: animatedURL)
            animatedImageView.isHidden = false
            imageLayer.contents = nil
        } else {
            animatedImageView.image = nil
            animatedImageView.isHidden = true
            imageLayer.contents = image
        }

        if let cropSession {
            cropOverlay.isHidden = false
            cropOverlay.session = cropSession
            // 选区边界 = 图片文档区（overlay 本地坐标，origin 恒为 0）
            cropOverlay.imageRect = CGRect(origin: .zero, size: docSize)
            cropOverlay.imageSize = originalSize
            cropOverlay.scale = scale
            cropOverlay.onChange = { [weak self] session in
                // NSView 事件回调非隔离，派发到主队列（FIFO 保序）
                DispatchQueue.main.async { self?.onCropChange?(session) }
            }
            cropOverlay.needsDisplay = true
        } else {
            cropOverlay.isHidden = true
        }

        if isNewImage || modeChanged {
            // 新图/切模式回到文档起点（阅读顺序：长截图从顶部开始；两模式互不带入滚动状态）
            contentView.scroll(to: .zero)
            reflectScrolledClipView(contentView)
        } else if let relativeCenter, docSize.width > 0, docSize.height > 0 {
            let newCenter = CGPoint(x: relativeCenter.x * docSize.width, y: relativeCenter.y * docSize.height)
            contentView.scroll(to: CGPoint(
                x: newCenter.x - contentView.bounds.width / 2,
                y: newCenter.y - contentView.bounds.height / 2
            ))
            reflectScrolledClipView(contentView)
        }
    }
}
