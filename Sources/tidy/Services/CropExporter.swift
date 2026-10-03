import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 裁剪导出（详设 §2.5）：EXIF 正向化后裁剪、命名建议、写盘。
enum CropExporter {
    enum ExportError: Error {
        case cannotDecode
        case cannotCrop
        case cannotEncode
    }

    /// 绕过渲染的 50MP 上限，重新读原文件全分辨率导出（详设 §7 内存策略）
    static func export(source url: URL, pixelRect: CGRect) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExportError.cannotDecode
        }
        let normalized = OrientationNormalizer.normalized(raw, orientation: OrientationNormalizer.orientation(of: source))
        guard let cropped = normalized.cropping(to: pixelRect) else {
            throw ExportError.cannotCrop
        }
        return cropped
    }

    /// 命名规则：原名 + " (n)"，n 从 2 起，跳过已存在（详设 §2.5）
    static func suggestURL(for source: URL, in directory: URL, extension ext: String? = nil) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let pathExtension = ext ?? source.pathExtension
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base) (\(n)).\(pathExtension)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            n += 1
        }
    }

    /// 输出格式：维持原格式；macOS 13 无 WebP 编码器 → 降级 PNG（详设 §7 WebP 编码）
    static func outputType(for source: URL) -> UTType {
        let type = (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: source.pathExtension.lowercased())
            ?? .jpeg
        if type.conforms(to: .webP), !canEncodeWebP {
            return .png
        }
        return type
    }

    static var canEncodeWebP: Bool {
        guard #available(macOS 14, *) else { return false }
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return identifiers.contains(UTType.webP.identifier)
    }

    /// 动图守卫：GIF / 动图 WebP（frame count > 1）不支持裁剪（详设 §2.5）
    /// 动图判定进程内缓存：同一文件的 UTI/帧数解析（CGImageSource）只做一次——
    /// 裁剪按钮置灰（canStartCropping）每次视图刷新都会调用，无缓存时每次都在主线程
    /// 重复解析 ImageIO，频繁切图时 CPU 打满（cpu_resource.diag 实证）
    private static let animatedCache = NSCache<NSURL, NSNumber>()

    static func isAnimatedImage(_ url: URL) -> Bool {
        if let cached = animatedCache.object(forKey: url as NSURL) { return cached.boolValue }
        let result: Bool
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let type = CGImageSourceGetType(source) as String?,
           type == UTType.gif.identifier || type == UTType.webP.identifier {
            result = CGImageSourceGetCount(source) > 1
        } else {
            result = false
        }
        animatedCache.setObject(NSNumber(value: result), forKey: url as NSURL)
        return result
    }

    /// 写盘质量策略（详设 §2.5）：PNG/TIFF/BMP 无损编码；JPEG 质量 1.0 重编码；HEIC 最高质量
    static func write(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ExportError.cannotEncode
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.cannotEncode
        }
    }
}
