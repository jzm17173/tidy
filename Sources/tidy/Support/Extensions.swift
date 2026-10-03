import CoreGraphics

extension CGImage {
    /// NSCache cost：RGBA 位图字节数
    var byteCost: Int { bytesPerRow * height }
}
