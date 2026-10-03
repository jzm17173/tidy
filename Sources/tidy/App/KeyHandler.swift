import AppKit

/// 键盘统一分发（详设 §2.6）：local monitor 按 mode 路由；
/// 模态面板守卫：NSOpenPanel（TCC 引导 / 打开其他文件夹）期间或事件不属于主窗口时直接放行。
@MainActor
final class KeyHandler {
    private let viewModel: GalleryViewModel
    private var monitor: Any?

    init(viewModel: GalleryViewModel) {
        self.viewModel = viewModel
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.route(event)
        }
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        // 模态面板守卫：Save/Open 面板运行期间（或事件发往其他窗口）不进路由
        if NSApp.modalWindow != nil { return event }
        guard let mainWindow = viewModel.mainWindow, event.window === mainWindow else { return event }
        // 带 Cmd/Ctrl/Option 的组合键放行给系统菜单（Shift 除外，裁剪微调用）；
        // 注意只交集这四个：方向键天然带 .function/.numericPad，交集 deviceIndependentFlagsMask 会误判
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        // ⌘C：有文本划选时复制所选（详设 §2.7）；无划选放行给系统
        if modifiers == [.command], event.keyCode == 8, event.charactersIgnoringModifiers == "c",
           case .viewing = viewModel.mode, viewModel.textSelection != nil {
            viewModel.copySelectedText()
            return nil
        }
        guard modifiers.isSubset(of: [.shift]) else { return event }

        switch viewModel.mode {
        case .viewing:
            switch event.keyCode {
            case 124: // →
                viewModel.next()
                return nil
            case 123: // ←
                viewModel.previous()
                return nil
            case 51: // ⌫
                viewModel.trashCurrent()
                return nil
            case 53 where viewModel.textSelection != nil: // Esc：清除文本划选
                viewModel.updateTextSelection(nil)
                return nil
            case 8 where event.charactersIgnoringModifiers == "c": // C
                viewModel.startCropping()
                return nil
            case 13 where event.charactersIgnoringModifiers == "w": // W：切换视图（完整预览 ⇄ 占满宽度）
                viewModel.toggleViewMode()
                return nil
            default:
                return event
            }
        case .cropping:
            // 裁剪态：Enter/Esc/方向键微调（Shift 10pt）+ W 切换视图，其余按键一律不响应
            let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 36, 76: // Enter / 小键盘 Enter
                viewModel.confirmCrop()
                return nil
            case 53: // Esc
                viewModel.cancelCrop()
                return nil
            case 13 where event.charactersIgnoringModifiers == "w": // W：切换视图
                viewModel.toggleViewMode()
                return nil
            case 123:
                viewModel.nudgeCrop(dx: -step, dy: 0)
                return nil
            case 124:
                viewModel.nudgeCrop(dx: step, dy: 0)
                return nil
            case 125:
                viewModel.nudgeCrop(dx: 0, dy: step)
                return nil
            case 126:
                viewModel.nudgeCrop(dx: 0, dy: -step)
                return nil
            default:
                return event
            }
        }
    }
}
