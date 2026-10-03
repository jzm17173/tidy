import CoreGraphics

enum Handle: Equatable {
    case topLeft, top, topRight, left, move, right, bottomLeft, bottom, bottomRight
}

/// 裁剪选区状态（详设 §2.5）。rectInView 使用**图片文档坐标系**（缩放后文档视图的坐标，
/// y 向下）：选区 = 像素坐标 × scale，滚动/窗口缩放均不影响换算。
struct CropSession: Equatable {
    var rectInView: CGRect
    var anchor: Handle?

    /// 进入裁剪模式时的默认选框：覆盖图片文档区 100%（全选）
    init(imageRectInView: CGRect) {
        self.rectInView = imageRectInView
        self.anchor = nil
    }

    /// 文档坐标 → 图像像素坐标（纯函数，便于单测）：
    /// pixel = rectInView / scale，clamp 到图像边界并取整
    func pixelRect(scale: CGFloat, imageSize: CGSize) -> CGRect {
        guard scale > 0, imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let raw = CGRect(
            x: rectInView.minX / scale,
            y: rectInView.minY / scale,
            width: rectInView.width / scale,
            height: rectInView.height / scale
        )
        let clipped = raw.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clipped.isNull, !clipped.isEmpty else { return .zero }
        let minX = clipped.minX.rounded(.down)
        let minY = clipped.minY.rounded(.down)
        let maxX = min(clipped.maxX.rounded(.up), imageSize.width)
        let maxY = min(clipped.maxY.rounded(.up), imageSize.height)
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    /// 拖拽手柄缩放选区：最小 10×10pt，clamp 在图片显示区域内
    static func resized(rect: CGRect, anchor: Handle, to point: CGPoint, in bounds: CGRect) -> CGRect {
        let minSize = Constants.minCropSize
        let p = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch anchor {
        case .topLeft:
            minX = min(p.x, maxX - minSize); minY = min(p.y, maxY - minSize)
        case .top:
            minY = min(p.y, maxY - minSize)
        case .topRight:
            maxX = max(p.x, minX + minSize); minY = min(p.y, maxY - minSize)
        case .left:
            minX = min(p.x, maxX - minSize)
        case .right:
            maxX = max(p.x, minX + minSize)
        case .bottomLeft:
            minX = min(p.x, maxX - minSize); maxY = max(p.y, minY + minSize)
        case .bottom:
            maxY = max(p.y, minY + minSize)
        case .bottomRight:
            maxX = max(p.x, minX + minSize); maxY = max(p.y, minY + minSize)
        case .move:
            break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 整体移动：clamp 在图片显示区域内，尺寸不变
    static func moved(rect: CGRect, by translation: CGSize, in bounds: CGRect) -> CGRect {
        var r = rect.offsetBy(dx: translation.width, dy: translation.height)
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        return r
    }

    /// 窗口尺寸变化时，把选区从旧图片显示区按比例映射到新显示区（保持相对图片的位置与比例）；
    /// 100% 全选映射后仍是 100% 全选
    static func remapped(rect: CGRect, from old: CGRect, to new: CGRect) -> CGRect {
        guard old.width > 0, old.height > 0 else { return rect }
        let fx = new.width / old.width
        let fy = new.height / old.height
        return CGRect(
            x: new.minX + (rect.minX - old.minX) * fx,
            y: new.minY + (rect.minY - old.minY) * fy,
            width: rect.width * fx,
            height: rect.height * fy
        )
    }
}
