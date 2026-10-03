import Foundation
import ImageIO

/// 图片元数据（只读 ImageIO 属性字典、不解码）
enum ImageMetadata {
    /// 图片点尺寸（EXIF 90°/270° 交换宽高），供缩放文档尺寸与裁剪坐标换算
    static func pointSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }
}
