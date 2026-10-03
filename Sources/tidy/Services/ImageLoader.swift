import Foundation
import ImageIO

/// 两级加载 + 内存缓存 + 50MP 降采样 + EXIF 转正（详设 §2.3）。
actor ImageLoader {
    enum LoadError: Error {
        case cannotDecode
    }

    private let cache = NSCache<NSURL, CGImage>()
    private let maxPixels: Int
    /// 测试观测用：缓存命中次数
    private(set) var cacheHits = 0

    init(maxPixels: Int = Constants.maxDecodePixels, cacheLimitBytes: Int = Constants.cacheLimitBytes) {
        self.maxPixels = maxPixels
        cache.totalCostLimit = cacheLimitBytes
    }

    /// 快速缩略图。maxPixel 是长边像素（视图长边 × backingScale）。
    /// kCGImageSourceCreateThumbnailWithTransform 会应用 EXIF 方向。
    /// 若全图已缓存则直接命中缓存。已取消的任务直接放弃（actor 串行队列不堆积陈旧解码）
    func thumbnail(for url: URL, maxPixel: CGFloat) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache.object(forKey: url as NSURL) {
            cacheHits += 1
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 全图：超过 50MP 用缩略图 API 降采样（参数是长边像素，按宽高比换算）；
    /// 否则全量解码并按 EXIF 方向转正。已取消的任务直接放弃（调用方按代次守卫忽略该错误）
    func fullImage(for url: URL) async throws -> CGImage {
        guard !Task.isCancelled else { throw LoadError.cannotDecode }
        if let cached = cache.object(forKey: url as NSURL) {
            cacheHits += 1
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw LoadError.cannotDecode
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1

        let result: CGImage
        if width * height > maxPixels {
            let aspect = Double(max(width, height)) / Double(min(width, height))
            let longEdge = sqrt(Double(maxPixels) * aspect)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(longEdge)
            ]
            guard let downsampled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw LoadError.cannotDecode
            }
            result = downsampled
        } else {
            guard let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw LoadError.cannotDecode
            }
            result = OrientationNormalizer.normalized(raw, orientation: orientation)
        }
        cache.setObject(result, forKey: url as NSURL, cost: result.byteCost)
        return result
    }

    /// 预加载相邻 ±1 张（失败静默，缓存超限由 NSCache 自动驱逐）
    func preload(urls: [URL]) async {
        for url in urls {
            _ = try? await fullImage(for: url)
        }
    }
}
