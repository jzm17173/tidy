import SwiftUI

@main
struct TidyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 单实例单窗口：SwiftUI Window 场景本身不生成 ⌘N（详设 §2.1）
        Window("tidy", id: "main") {
            ContentView(viewModel: appDelegate.viewModel)
        }
    }
}
