import Foundation
import UniformTypeIdentifiers

/// 目录枚举：白名单 UTI 过滤、跳过隐藏文件、自然排序（详设 §2.2）。
enum DirectoryScanner {
    /// PRD 白名单：JPEG/PNG/HEIC/GIF/WebP/TIFF/BMP，不用 public.image 兜底（避免 RAW/SVG 混入）
    static let allowedTypes: [UTType] = [.jpeg, .png, .gif, .webP, .heic, .bmp, .tiff]

    static func isSupported(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return allowedTypes.contains(where: { type.conforms(to: $0) })
        }
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()) {
            return allowedTypes.contains(where: { type.conforms(to: $0) })
        }
        return false
    }

    static func scan(directory: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentTypeKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        )
        return urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isHiddenKey]),
                  values.isHidden != true,
                  let type = values.contentType else { return false }
            return allowedTypes.contains(where: { type.conforms(to: $0) })
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// TCC / 权限类错误归类（无专门 TCC 错误码，按错误域+code 判断，详设 §2.1）
    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileReadNoPermissionError
                || nsError.code == NSFileWriteNoPermissionError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == EPERM || nsError.code == EACCES
        }
        return false
    }
}
