import AppKit

/// NSServices provider：接收 public.file-url（Info.plist NSServices 声明，详设 §2.1）。
/// NSMessage 为 openFile，方法签名固定为服务消息三段式。
extension AppDelegate {
    @objc func openFile(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        viewModel.mainWindow?.makeKeyAndOrderFront(nil)
        viewModel.open(urls)
    }
}
