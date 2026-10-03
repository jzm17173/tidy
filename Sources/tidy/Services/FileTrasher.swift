import Foundation

/// 删除到废纸篓（详设 §2.4）。免确认的前提是仅走废纸篓、可恢复。
enum FileTrasher {
    static func trash(_ url: URL) throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    /// 「文件已不存在」错误归类：此类失败应把文件移出图集并跳下一张
    static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError
                || nsError.code == NSFileReadNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == ENOENT
        }
        return false
    }
}
