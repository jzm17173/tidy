import CoreGraphics

enum Constants {
    /// 解码上限（像素总数）：超过则降采样渲染（详设 §2.3 / §7 内存策略）
    static let maxDecodePixels = 50_000_000
    /// NSCache 总上限：容得下一张 50MP 全图（≈200MB）+ 预加载余量
    static let cacheLimitBytes = 512 * 1024 * 1024
    static let toastDurationNanos: UInt64 = 3_000_000_000
    /// 选区下限 10×10pt（视图坐标）
    static let minCropSize: CGFloat = 10
    /// 手柄命中热区
    static let handleHotZone: CGFloat = 12
    /// 文本识别用的降采样长边（OCR 精度与耗时的平衡；归一化坐标与分辨率无关）
    static let textRecognitionMaxPixel: CGFloat = 2560
}
