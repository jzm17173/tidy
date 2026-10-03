import CoreGraphics
import ImageIO

/// EXIF 方向正向化：显示与导出共用同一套转正逻辑（详设 §2.3）。
enum OrientationNormalizer {
    static func orientation(of source: CGImageSource) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let value = props[kCGImagePropertyOrientation] as? Int else { return 1 }
        return value
    }

    /// 按 EXIF orientation（1-8）把存储像素旋转/翻转到视觉正向。
    /// 位图上下文中 y=0 对应结果图的首行（往返恒等），直接按视觉坐标推导仿射变换。
    static func normalized(_ image: CGImage, orientation: Int) -> CGImage {
        guard (2...8).contains(orientation) else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let swapped = orientation >= 5
        let outW = swapped ? Int(h) : Int(w)
        let outH = swapped ? Int(w) : Int(h)

        // 位图上下文为 y-up（user y=0 对应内存末行），draw 把图像首行画在 rect 的 max-y；
        // concatenating 语义：receiver.concatenating(x) = 先应用 x 再应用 receiver（均经实测标定）
        let transform: CGAffineTransform
        switch orientation {
        case 2: // 水平翻转
            transform = CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1)
        case 3: // 旋转 180°
            transform = CGAffineTransform(translationX: w, y: h).rotated(by: .pi)
        case 4: // 垂直翻转
            transform = CGAffineTransform(translationX: 0, y: h).scaledBy(x: 1, y: -1)
        case 5: // leftMirrored
            transform = CGAffineTransform(translationX: h, y: w)
                .scaledBy(x: 1, y: -1).rotated(by: .pi / 2)
        case 6: // 旋转 90° CW 后显示
            transform = CGAffineTransform(translationX: 0, y: w).rotated(by: -.pi / 2)
        case 7: // rightMirrored
            transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        default: // 8：旋转 90° CCW 后显示
            transform = CGAffineTransform(translationX: h, y: 0).rotated(by: .pi / 2)
        }

        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }
}
