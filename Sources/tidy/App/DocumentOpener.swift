import AppKit

/// AppDelegate：SwiftUI 生命周期下必须用 @NSApplicationDelegateAdaptor，
/// 否则 application(_:open:) 不会被调用（详设 §2.1）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = GalleryViewModel()
    private lazy var keyHandler = KeyHandler(viewModel: viewModel)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.servicesProvider = self
        keyHandler.install()
    }

    /// 再次打开（无论是否同一目录）：激活现有窗口，切换目录重建图集（PRD FR-1 实例模型）
    func application(_ application: NSApplication, open urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        viewModel.mainWindow?.makeKeyAndOrderFront(nil)
        viewModel.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
