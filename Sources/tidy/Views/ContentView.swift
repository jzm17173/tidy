import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: GalleryViewModel
    @ObservedObject var displayState: ImageDisplayState
    @State private var window: NSWindow?
    @State private var didApplyInitialFrame = false

    init(viewModel: GalleryViewModel) {
        self.viewModel = viewModel
        self.displayState = viewModel.displayState
    }

    var body: some View {
        ZStack {
            // 深色背景（PRD FR-5）
            Color(red: 0.11, green: 0.11, blue: 0.12)
                .ignoresSafeArea()

            if viewModel.items.isEmpty {
                EmptyStateView(onOpenFolder: { viewModel.presentOpenPanelForDirectory() })
            } else {
                if let item = viewModel.currentItem, !item.isSupported {
                    ErrorStateView(message: "不支持的图片格式")
                } else if displayState.error != nil {
                    ErrorStateView(message: "无法显示该图片（文件可能已损坏）")
                } else {
                    ImageCanvasView(
                        image: displayState.image,
                        animatedURL: displayState.animatedURL,
                        imageKey: viewModel.currentItem?.url,
                        docSize: viewModel.imageDocRect.size,
                        fitInside: viewModel.viewMode == .fit,
                        cropSession: {
                            if case .cropping(let session) = viewModel.mode { return session }
                            return nil
                        }(),
                        originalSize: viewModel.originalImageSize ?? .zero,
                        scale: viewModel.scale,
                        onSizeChange: { viewModel.updateCanvasSize($0) },
                        onCropChange: { viewModel.updateCropSession($0) }
                    )
                }
            }

            VStack {
                Spacer()
                if let toast = viewModel.toast {
                    ToastView(toast: toast)
                        .padding(.bottom, 24)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.toast)
        }
        // 图片区深色（colorScheme 只作用于内容，标题栏/工具栏跟随系统外观，PRD FR-5）
        .environment(\.colorScheme, .dark)
        // 操作按钮收进标题栏右侧，与全屏按钮同一区域（PRD FR-5，参考 Mac 预览）
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                switch viewModel.mode {
                case .viewing:
                    Button { viewModel.toggleViewMode() } label: {
                        Image(systemName: viewModel.viewMode == .fit
                              ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    }
                    .help(viewModel.viewMode == .fit ? "占满宽度（W）" : "完整预览（W）")
                    .disabled(viewModel.originalImageSize == nil)

                    Button { viewModel.trashCurrent() } label: {
                        Image(systemName: "trash")
                    }
                    .help("移到废纸篓（⌫）")
                    .disabled(viewModel.currentItem == nil)

                    Button { viewModel.startCropping() } label: {
                        Image(systemName: "crop")
                    }
                    .help("裁剪（C）")
                    .disabled(viewModel.currentItemIsAnimated || viewModel.currentItem == nil)

                case .cropping:
                    Button { viewModel.confirmCrop() } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help("保存裁剪结果（Enter）")

                    Button { viewModel.cancelCrop() } label: {
                        Image(systemName: "xmark")
                    }
                    .help("退出裁剪（Esc）")
                }
            }
        }
        .background(WindowAccessor { resolved in
            // 窗口固定 1:1 正方形：比例锁定 + 最小 480×480（PRD FR-5）
            resolved.contentAspectRatio = NSSize(width: 1, height: 1)
            resolved.contentMinSize = NSSize(width: 480, height: 480)
            if window !== resolved {
                window = resolved
                viewModel.configureWindowOnResolve(resolved)
                if !didApplyInitialFrame {
                    didApplyInitialFrame = true
                    // 初始正方形：近满高，屏幕可用区内居中
                    if let screen = resolved.screen ?? NSScreen.main {
                        let visible = screen.visibleFrame
                        let side = max(480, min(visible.width - 36, visible.height - 87))
                        var frame = resolved.frameRect(
                            forContentRect: CGRect(origin: .zero, size: CGSize(width: side, height: side))
                        )
                        frame.origin.x = visible.midX - frame.width / 2
                        frame.origin.y = visible.midY - frame.height / 2
                        resolved.setFrame(frame, display: true)
                    }
                }
            }
            resolved.title = viewModel.windowTitle
        })
        .onChange(of: viewModel.windowTitle) { title in
            window?.title = title
        }
    }
}
