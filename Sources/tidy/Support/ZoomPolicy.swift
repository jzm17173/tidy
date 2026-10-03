import CoreGraphics

/// 图片视图模式（PRD FR-1）：完整预览 / 占满宽度
enum ViewMode: Equatable {
    /// 完整预览：整张图 fit 进可视区，不超 100%（小图不放大）
    case fit
    /// 占满宽度：图片宽度铺满可视区，高度超出部分竖向滚动（长截图阅读模式）
    case fillWidth
}

/// 视图模式与缩放策略（PRD FR-1/FR-5）：scale = 图片 1px 对应的点数（1.0 = 100%，1px = 1pt）。
enum ZoomPolicy {
    /// 占满宽度的放大上限（避免极窄图被放到失真）
    static let maxScale: CGFloat = 8
    /// 巨高图阈值：高/宽 ≥ 3 视为长截图，默认占满宽度
    static let tallImageAspectRatio: CGFloat = 3

    /// fit 缩放比：图片完整显示在视图内（小图会 >1，即放大）
    static func fitScale(imageSize: CGSize, viewSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    }

    /// 占满宽度缩放比：图片宽度 = 可视区宽度（封顶 maxScale）
    static func fillWidthScale(imageSize: CGSize, viewSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return min(viewSize.width / imageSize.width, maxScale)
    }

    /// 指定视图模式下的缩放比（fit 不超 100%）
    static func scale(for mode: ViewMode, imageSize: CGSize, viewSize: CGSize) -> CGFloat {
        switch mode {
        case .fit:
            return min(1, fitScale(imageSize: imageSize, viewSize: viewSize))
        case .fillWidth:
            return fillWidthScale(imageSize: imageSize, viewSize: viewSize)
        }
    }

    /// 默认视图模式：巨高图（长截图）占满宽度，其余完整预览（巨宽图不做特殊优化）
    static func defaultMode(imageSize: CGSize) -> ViewMode {
        guard imageSize.width > 0, imageSize.height > 0 else { return .fit }
        return imageSize.height / imageSize.width >= tallImageAspectRatio ? .fillWidth : .fit
    }
}
