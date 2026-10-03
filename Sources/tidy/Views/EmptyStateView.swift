import SwiftUI

/// 空态页：目录无图片（或全部失效）时提示，按钮唤起 NSOpenPanel（PRD FR-5）
struct EmptyStateView: View {
    let onOpenFolder: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("没有可显示的图片")
                .font(.title3)
            Text("该目录中没有支持的图片（JPEG / PNG / HEIC / GIF / WebP / TIFF / BMP）")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("打开其他文件夹", action: onOpenFolder)
        }
    }
}

/// 错误占位页：损坏/不支持的图片，可继续 ←/→ 离开（PRD FR-1 异常）
struct ErrorStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.title3)
            Text("按 ← / → 继续浏览其他图片")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
