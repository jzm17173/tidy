import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 用 ImageIO 程序化生成测试图片，不提交二进制资源（详设 §5 测试要点）。
enum TestImageFactory {
    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// splitColor=true 时左半红右半蓝（用于验证 EXIF 转正后像素落位）
    static func makeImage(width: Int, height: Int, splitColor: Bool = false) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        if splitColor {
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        } else {
            context.setFillColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()!
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType, orientation: Int? = nil) throws -> URL {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "TestImageFactory", code: 1)
        }
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "TestImageFactory", code: 2)
        }
        return url
    }

    static func writeGIF(frames: Int, size: CGSize, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw NSError(domain: "TestImageFactory", code: 3)
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
        ] as CFDictionary
        for _ in 0..<frames {
            CGImageDestinationAddImage(
                destination,
                makeImage(width: Int(size.width), height: Int(size.height)),
                frameProperties
            )
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "TestImageFactory", code: 4)
        }
    }

    /// 采样像素（x,y 以显示首行左端为原点）
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return (data[offset], data[offset + 1], data[offset + 2])
    }
}
