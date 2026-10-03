import CoreGraphics
import Foundation

/// 当前图片的两级显示状态：缩略图先行，高清异步替换（详设 §2.2 切换流程）。
@MainActor
final class ImageDisplayState: ObservableObject {
    @Published private(set) var image: CGImage?
    /// GIF / 动图 WebP：交给 NSImageView 播放，不走 CGImage 缓存帧
    @Published private(set) var animatedURL: URL?
    @Published private(set) var error: Error?

    private var generation = 0

    func load(_ url: URL, loader: ImageLoader, thumbnailMaxPixel: CGFloat) {
        generation += 1
        let gen = generation
        image = nil
        animatedURL = nil
        error = nil

        if CropExporter.isAnimatedImage(url) {
            animatedURL = url
            return
        }

        Task {
            if let thumb = await loader.thumbnail(for: url, maxPixel: thumbnailMaxPixel) {
                guard gen == generation else { return }
                image = thumb
            }
            do {
                let full = try await loader.fullImage(for: url)
                guard gen == generation else { return }
                image = full
            } catch {
                guard gen == generation else { return }
                // 解码失败（损坏）→ 错误占位页，可继续切换（详设 §2.2）
                self.error = error
            }
        }
    }

    func clear() {
        generation += 1
        image = nil
        animatedURL = nil
        error = nil
    }
}
