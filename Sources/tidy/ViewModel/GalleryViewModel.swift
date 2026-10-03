import AppKit
import Foundation

enum Mode: Equatable {
    case viewing
    case cropping(CropSession)
}

struct GalleryItem: Identifiable, Equatable {
    let url: URL
    /// 白名单外格式（RAW/SVG 等）：保留在图集中，显示错误占位页，←/→ 可离开（详设 §2.2）
    var isSupported: Bool = true
    var id: URL { url }
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
}

/// 核心状态机：图集、索引、删除、裁剪模式（详设 §2.2）。
@MainActor
final class GalleryViewModel: ObservableObject {
    @Published var items: [GalleryItem] = []
    @Published var index: Int = 0
    @Published var mode: Mode = .viewing
    @Published var toast: Toast?
    /// 画布可视区尺寸（fit 换算依赖），由 ImageCanvasView 经 updateCanvasSize 回写
    @Published private(set) var canvasSize: CGSize = .zero
    /// 当前图原始像素尺寸（EXIF 已正向化），ImageIO 读取；加载失败/不支持时为 nil
    @Published private(set) var originalImageSize: CGSize?
    /// 当前缩放：图片 1px 对应的点数（1.0 = 100%），由视图模式经 ZoomPolicy 得出
    @Published private(set) var scale: CGFloat = 1
    /// 当前视图模式：完整预览 / 占满宽度（PRD FR-1），切换图片时按图重置
    @Published private(set) var viewMode: ViewMode = .fit

    let displayState = ImageDisplayState()
    let loader: ImageLoader
    weak var mainWindow: NSWindow?

    private var toastGeneration = 0

    init(loader: ImageLoader = ImageLoader()) {
        self.loader = loader
    }

    var currentItem: GalleryItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    /// 窗口标题：目录名 — 文件名 (3/24)
    var windowTitle: String {
        guard let item = currentItem else { return "tidy" }
        return "\(item.url.deletingLastPathComponent().lastPathComponent) — \(item.url.lastPathComponent) (\(index + 1)/\(items.count))"
    }

    /// 图片文档显示区（origin 恒为 0，尺寸 = 原始点尺寸 × scale）：裁剪选框的边界与换算基准
    var imageDocRect: CGRect {
        guard let size = originalImageSize else { return .zero }
        return CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
    }

    var currentItemIsAnimated: Bool {
        guard let item = currentItem else { return false }
        return CropExporter.isAnimatedImage(item.url)
    }

    // MARK: - 打开（详设 §2.2 / 时序 3.1）

    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        // 打开事件 × 裁剪模式冲突：直接丢弃选区切换目录，不弹确认（详设 §2.1）
        mode = .viewing

        var isDirectory = false
        if let values = try? first.resourceValues(forKeys: [.isDirectoryKey]) {
            isDirectory = values.isDirectory == true
        }

        if isDirectory {
            let scanned = scanWithTCCFallback(directory: first)
            items = scanned.map { GalleryItem(url: $0) }
            index = 0
            afterIndexChanged()
            return
        }

        let directory = first.deletingLastPathComponent()
        var scanned = scanWithTCCFallback(directory: directory)
        // 被打开文件不在白名单（或目录枚举被 TCC 拒绝）→ 仍插入图集，本身显示错误占位页
        if !scanned.contains(first) {
            let insertAt = scanned.firstIndex {
                $0.lastPathComponent.localizedStandardCompare(first.lastPathComponent) == .orderedDescending
            } ?? scanned.count
            scanned.insert(first, at: insertAt)
        }
        items = scanned.map { GalleryItem(url: $0, isSupported: DirectoryScanner.isSupported($0)) }
        index = items.firstIndex(where: { $0.url == first }) ?? 0
        afterIndexChanged()
    }

    /// 枚举目录；遇 TCC 权限拒绝 → 每次都弹 NSOpenPanel 引导；用户取消 → 返回空（调用方降级为单项图集）
    private func scanWithTCCFallback(directory: URL) -> [URL] {
        do {
            return try DirectoryScanner.scan(directory: directory)
        } catch {
            guard DirectoryScanner.isPermissionError(error) else { return [] }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = directory
            panel.message = "tidy 需要访问该文件夹，才能浏览目录中的其他图片"
            panel.prompt = "授予访问"
            guard panel.runModal() == .OK, let chosen = panel.url else {
                showToast("仅显示当前图片，可点击「打开其他文件夹」选择目录")
                return []
            }
            return (try? DirectoryScanner.scan(directory: chosen)) ?? []
        }
    }

    /// 空态页按钮：NSOpenPanel 选目录（无沙盒，选择即获得访问同意）
    func presentOpenPanelForDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open([url])
    }

    // MARK: - 切换（详设 §2.2：循环、懒校验、预加载 ±1）

    func next() { move(by: 1) }
    func previous() { move(by: -1) }

    private func move(by delta: Int) {
        guard mode == .viewing, !items.isEmpty, delta != 0 else { return }
        // 探测预算取初始图集大小（不随图集收缩而缩小）：每轮要么命中返回、要么移除一项，最多探测一轮
        var probesLeft = items.count
        while probesLeft > 0, !items.isEmpty {
            let candidate = items.count > 1 ? (index + delta + items.count) % items.count : index
            if isReachable(items[candidate].url) {
                index = candidate
                afterIndexChanged()
                return
            }
            // 文件已被外部删除：从图集移除并继续找下一张有效项（PRD FR-2）
            items.remove(at: candidate)
            if items.isEmpty { break }
            // 被移除项在当前张之前 → 当前张下标同步前移一位；之后则不动（详设 §2.2 切换流程）
            if candidate < index { index -= 1 }
            probesLeft -= 1
        }
        // 全部失效 → 空态页
        if items.isEmpty {
            index = 0
            clearCurrentImage()
        }
    }

    private func isReachable(_ url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) == true
    }

    /// 清空当前图显示（空态页 / 不支持格式 / 全部失效）：显示状态、原始尺寸、缩放与视图模式一并复位
    private func clearCurrentImage() {
        displayState.clear()
        originalImageSize = nil
        scale = 1
        viewMode = .fit
    }

    private func afterIndexChanged() {
        guard let item = currentItem, item.isSupported else {
            clearCurrentImage()
            return
        }
        originalImageSize = ImageMetadata.pointSize(of: item.url)
        resetViewMode()
        let backingScale = mainWindow?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let longEdge = max(canvasSize.width, canvasSize.height) * backingScale
        displayState.load(item.url, loader: loader, thumbnailMaxPixel: max(longEdge, 512))
        let neighbors = [index - 1, index + 1]
            .filter { items.indices.contains($0) }
            .map { items[$0].url }
        Task { await loader.preload(urls: neighbors) }
    }

    // MARK: - 删除（详设 §2.4 / 时序 3.2）

    func trashCurrent() {
        guard mode == .viewing, let item = currentItem else { return }
        // 先判空再算 nextTarget，否则单图目录会算出 index-1 = -1
        let nextTarget: Int? = items.count > 1 ? (index + 1 < items.count ? index : index - 1) : nil
        do {
            try FileTrasher.trash(item.url)
            removeCurrentAndMove(to: nextTarget)
            showToast("已移到废纸篓：\(item.url.lastPathComponent)")
        } catch {
            if FileTrasher.isMissingFileError(error) {
                removeCurrentAndMove(to: nextTarget)
                showToast("文件已不存在：\(item.url.lastPathComponent)")
            } else {
                // 占用/权限失败：文件还在盘上，留在当前张，绝不移出图集
                showToast("删除失败：\(item.url.lastPathComponent)")
            }
        }
    }

    private func removeCurrentAndMove(to nextTarget: Int?) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        if let target = nextTarget, !items.isEmpty {
            index = min(target, items.count - 1)
            afterIndexChanged()
        } else {
            index = 0
            clearCurrentImage()
        }
    }

    // MARK: - 裁剪（详设 §2.5 / 时序 3.3）

    /// 裁剪入口不可进入的原因（nil = 可进入）：按钮置灰与 C 键入口共用同一来源，避免两处判据漂移
    private enum CropEntryBlocker: Equatable {
        case notViewing      // 不在查看模式（裁剪态另有键位路由）
        case noItem          // 无当前项
        case unsupported     // 白名单外格式（画面为错误占位页）
        case animated        // GIF / 动图 WebP
        case notReady        // 图像未就绪或有解码错误（错误占位页）
    }

    /// 裁剪入口守卫（详设 §2.5）：查看模式 + 当前项受支持 + 非动图 + 无解码错误 + 图像与原始尺寸就绪
    private var cropEntryBlocker: CropEntryBlocker? {
        guard mode == .viewing else { return .notViewing }
        guard let item = currentItem else { return .noItem }
        guard item.isSupported else { return .unsupported }
        if currentItemIsAnimated { return .animated }
        guard imageReadyForCropping else { return .notReady }
        return nil
    }

    /// 标题栏裁剪按钮的置灰判据（ContentView 的 `.disabled`）
    var canStartCropping: Bool { cropEntryBlocker == nil }

    /// 图像侧就绪条件：解码错误态（错误占位页）或两级加载未就绪（image 为空）都不得进入裁剪
    private var imageReadyForCropping: Bool {
        displayState.error == nil && displayState.image != nil && originalImageSize != nil
    }

    func startCropping() {
        let blocker = cropEntryBlocker
        // 动图是唯一给反馈的不可裁剪原因（详设 §2.5 动图守卫）；其余静默返回，按钮已置灰
        if blocker == .animated {
            showToast("动图暂不支持裁剪")
            return
        }
        guard blocker == nil else { return }
        mode = .cropping(CropSession(imageRectInView: imageDocRect))
    }

    func updateCropSession(_ session: CropSession) {
        guard case .cropping = mode else { return }
        mode = .cropping(session)
    }

    func nudgeCrop(dx: CGFloat, dy: CGFloat) {
        guard case .cropping(var session) = mode else { return }
        session.rectInView = CropSession.moved(
            rect: session.rectInView,
            by: CGSize(width: dx, height: dy),
            in: imageDocRect
        )
        mode = .cropping(session)
    }

    func cancelCrop() {
        guard case .cropping = mode else { return }
        mode = .viewing
    }

    func confirmCrop() {
        guard case .cropping(let session) = mode,
              let item = currentItem,
              let imageSize = originalImageSize else { return }
        let source = item.url
        let outputType = CropExporter.outputType(for: source)
        let directory = source.deletingLastPathComponent()
        // macOS 13 WebP 降级 PNG：保存文件名同步改 PNG 扩展名（详设 §2.5）
        let degradedToPNG = outputType == .png && !source.pathExtension.lowercased().hasPrefix("png")
        let suggested = CropExporter.suggestURL(
            for: source, in: directory,
            extension: degradedToPNG ? "png" : nil
        )
        // 选区为图片文档坐标，除以 scale 即得原图像素选区（不依赖降采样显示图）
        let pixelRect = session.pixelRect(scale: scale, imageSize: imageSize)
        guard !pixelRect.isEmpty else {
            showToast("选区无效")
            return
        }

        // 直接保存到原图同目录（不弹另存面板，PRD FR-4）：文件名按命名规则自动取、跳过已存在
        let destination = suggested
        do {
            let cropped = try CropExporter.export(source: source, pixelRect: pixelRect)
            try CropExporter.write(cropped, to: destination, type: outputType)
            // 新文件插入原图之后，不自动跳转
            if let sourceIndex = items.firstIndex(where: { $0.url == source }) {
                items.insert(GalleryItem(url: destination), at: sourceIndex + 1)
            }
            mode = .viewing
            if degradedToPNG {
                showToast("macOS 13 不支持 WebP 编码，已保存为 PNG：\(destination.lastPathComponent)")
            } else {
                showToast("已保存：\(destination.lastPathComponent)")
            }
        } catch {
            showToast("保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 视图模式（PRD FR-1：完整预览 / 占满宽度，W 或标题栏按钮切换）

    /// 切换视图模式：完整预览 ⇄ 占满宽度
    func toggleViewMode() {
        guard let size = originalImageSize else { return }
        let newMode: ViewMode = viewMode == .fit ? .fillWidth : .fit
        let newScale = ZoomPolicy.scale(for: newMode, imageSize: size, viewSize: canvasSize)
        viewMode = newMode
        guard newScale != scale else { return }
        remapCropSelection(from: scale, to: newScale, imageSize: size)
        scale = newScale
    }

    /// 切图时重置为该图的默认视图模式（巨高图占满宽度，其余完整预览）
    private func resetViewMode() {
        guard let size = originalImageSize else {
            scale = 1
            viewMode = .fit
            return
        }
        viewMode = ZoomPolicy.defaultMode(imageSize: size)
        scale = ZoomPolicy.scale(for: viewMode, imageSize: size, viewSize: canvasSize)
    }

    /// 缩放/画布变化时，裁剪选区（图片文档坐标）按新旧文档尺寸等比映射，保持相对图片的位置与大小（PRD FR-4）
    private func remapCropSelection(from oldScale: CGFloat, to newScale: CGFloat, imageSize: CGSize) {
        guard case .cropping(var session) = mode, oldScale > 0, oldScale != newScale else { return }
        session.rectInView = CropSession.remapped(
            rect: session.rectInView,
            from: CGRect(x: 0, y: 0, width: imageSize.width * oldScale, height: imageSize.height * oldScale),
            to: CGRect(x: 0, y: 0, width: imageSize.width * newScale, height: imageSize.height * newScale)
        )
        mode = .cropping(session)
    }

    // MARK: - 窗口与画布（PRD FR-5：窗口固定 1:1，打开/切换均不改变窗口）

    /// ContentView resolve 窗口后调用
    func configureWindowOnResolve(_ window: NSWindow) {
        mainWindow = window
        // 清理旧版本遗留的窗口记忆
        UserDefaults.standard.removeObject(forKey: "TidyUserWindowFrame")
        UserDefaults.standard.removeObject(forKey: "TidyUserWindowFrameV2")
    }

    /// 画布可视区尺寸变化：两种视图模式都跟随窗口（fit 重排 / 宽度始终铺满），
    /// 按当前模式重算缩放；裁剪选区随缩放等比重映射
    func updateCanvasSize(_ newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0 else { return }
        let oldScale = scale
        canvasSize = newSize
        guard let size = originalImageSize else { return }
        let newScale = ZoomPolicy.scale(for: viewMode, imageSize: size, viewSize: newSize)
        guard newScale != oldScale else { return }
        remapCropSelection(from: oldScale, to: newScale, imageSize: size)
        scale = newScale
    }

    // MARK: - Toast（3s 自动消失，PRD FR-3）

    func showToast(_ message: String) {
        toastGeneration += 1
        let generation = toastGeneration
        toast = Toast(message: message)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Constants.toastDurationNanos)
            guard let self, self.toastGeneration == generation else { return }
            self.toast = nil
        }
    }
}
