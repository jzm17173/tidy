# tidy · 详细设计文档

> 版本：v1.0　平台：macOS 13+　语言：Swift 5.9（SwiftUI + AppKit）
> 关联文档：[需求文档 PRD](tidy-需求文档-PRD.md)、[技术选型](图片预览工具-技术方案.md)

## 1. 总体架构

单进程单窗口应用，三层结构，零第三方依赖：

```
┌─────────────────────────────────────────────┐
│ App 层    TidyApp / WindowRouter / ServiceReceiver │  入口、窗口、外部打开
├─────────────────────────────────────────────┤
│ ViewModel 层  GalleryViewModel（图集状态机）        │  目录枚举/索引/删除/模式
├─────────────────────────────────────────────┤
│ View 层    ImageView + CropOverlayView + Toolbar   │  渲染与交互
├─────────────────────────────────────────────┤
│ Service 层  ImageLoader / FileTrasher / CropExporter │  纯函数能力，可单测
└─────────────────────────────────────────────┘
```

数据流单向：用户输入 → `GalleryViewModel` 变更状态 → SwiftUI 重渲染；大图渲染走 AppKit 自绘视图，绕开 SwiftUI 大图性能问题。

## 2. 模块设计

### 2.1 App 层

```
TidyApp.swift          @main，单实例单窗口：SwiftUI Window（macOS 13+，其场景本身
                       不生成 ⌘N）；@NSApplicationDelegateAdaptor 挂 AppDelegate
                       （否则 SwiftUI 生命周期下 application(_:open:) 不会被调用）
DocumentOpener.swift   AppDelegate：application(_:open:) 回调（CFBundleDocumentTypes 只是声明，
                       打开事件走此回调，非 LSHandler 回调）
ServiceReceiver.swift  NSServices provider：接收 public.file-url，同上
```

**单实例策略**：应用生命周期内只有一个窗口、一个 `GalleryViewModel`。再次打开任何图片（含不同目录）时：若应用在前台 → 直接在现有窗口切换目录重建图集并定位到该文件；若在后台 → 先激活窗口再切换。无多窗口状态管理。

**打开事件 × 裁剪模式的冲突处理**：若当前处于裁剪模式（`mode == .cropping`），新的打开事件直接 **丢弃选区、退出裁剪模式、切换目录**。理由：未保存的选区只是坐标、原图从未被修改，丢弃零数据损失；用户主动打开新图即意图转移，不弹确认框（与"删除不确认"同一原则）。无需 toast——切换后标题变化即是反馈。特例：NSOpenPanel（TCC 引导 / 打开其他文件夹）打开期间系统会**排队**打开事件，面板关闭后事件照常送达 → 走同一条规则（丢弃选区并切换目录），无需特殊代码。

- `Info.plist` 关键声明：

```xml
CFBundleDocumentTypes → LSItemContentTypes: [public.image], LSHandlerRank: Alternate
   （RAW/SVG 等仍会出现在"打开方式"里——运行时在 open() 入口按 PRD 白名单 UTI 二次过滤：
    不在白名单的文件**仍枚举其所在目录的白名单图片作为图集**，仅该项本身显示
    错误占位页「不支持的图片格式」，←/→ 可离开；详见 2.2 open(_:)）
NSServices → NSSendTypes: [public.file-url], NSMessage: openFile
Hardened Runtime（公证必需；不开 App Sandbox——非 App Store 分发无此要求）
```

> **无沙盒 ≠ 无权限**：桌面/文稿/下载等目录仍受 macOS TCC 隐私同意约束。从"下载"里用打开方式打开一张图，通常只授权了那一个文件，**枚举同目录、删除旁边的图可能失败**——这恰是 tidy 的主场景。策略：`open(_:)` 枚举目录时若 `contentsOfDirectory` 抛权限类错误（`NSFileReadNoPermissionError` / `EPERM` 一类，无专门 TCC 错误码，按错误域+code 归类判断），**每次都**弹 NSOpenPanel 引导用户选中该目录（点选授予的目录访问仅在本进程生命周期内可靠，下次打开可能再次需要，因此不做"只在首次"的假设）；**用户取消面板** → 本次打开按"无法枚举目录"处理：图集只有被打开的这一张文件，toast 提示可选「打开其他文件夹」。

### 2.2 GalleryViewModel（核心状态机）

```swift
enum Mode { case viewing, cropping(CropSession) }

@MainActor final class GalleryViewModel: ObservableObject {
    @Published var items: [GalleryItem]                // 图集（测试直接构造图集，不设 private(set)）
    @Published var index: Int
    @Published var mode: Mode = .viewing
    @Published var toast: Toast?
    let displayState: ImageDisplayState                // 缩略图→高清 两级

    func open(_ urls: [URL])
    // 多文件打开（PRD FR-1）：取第一张文件所在目录构建图集，定位到第一张；
    // 1. 图集恒为「目录枚举出的白名单图片」；被打开文件按白名单 UTI 过滤后定位：
    //    - 在白名单 → 正常定位 index
    //    - 不在白名单（RAW/SVG）→ **仍枚举其所在目录的白名单图片**作为图集，
    //      该项显示错误占位页「不支持的图片格式」，←/→ 可离开
    //    - 打开的目录无任何白名单图片 → 单项图集 + 错误占位页
    // 2. 枚举目录；遇 TCC 权限拒绝 → 弹 NSOpenPanel 引导（见 2.1）；
    //    用户取消 → 图集只含被打开的文件，toast 提示可"打开其他文件夹"
    // 3. 被打开文件若解码失败（损坏）→ 定位到它并显示错误占位页，可继续切换
    // 4. 定位 index、预加载 ±1、更新标题（目录名 — 文件名 (i/n)）
    func next() / previous()           // 循环切换，跳过已失效文件
    func trashCurrent()                // FR-3
    func startCropping() / confirmCrop() / cancelCrop()

    func updateCanvasSize(_:)
    // 画布可视区尺寸回写：两种视图模式都跟随窗口，按当前模式重算缩放（ZoomPolicy）；
    // 裁剪中的选区按新旧文档尺寸 remap（CropSession.remapped），
    // 保持相对图片的位置与比例（PRD FR-4 自适应）
    func toggleViewMode()
    // 视图模式切换（PRD FR-1）：完整预览 ⇄ 占满宽度；规则见 2.6 视图模式
}

struct GalleryItem: Identifiable {
    let url: URL
    var isSupported: Bool = true       // 白名单外格式（RAW/SVG 等）：仍留在图集，
                                       // 该项显示错误占位页，←/→ 可离开
    var id: URL { url }
}
```

**目录枚举**：`FileManager.contentsOfDirectory(at:includingPropertiesForKeys:)` 请求 `.contentTypeKey, .isHiddenKey`。过滤规则：
1. 跳过隐藏文件（`.isHiddenKey == true` 及 `.` 开头）；
2. UTI **白名单**（`public.jpeg/public.png/public.gif/public.webp/public.heic/public.bmp/public.tiff`，即 PRD 支持格式），不用 `public.image` 兜底（避免混入 RAW/SVG）；
3. 自然排序（`localizedStandardCompare`）。

**切换流程**（`next()` 为例）：

1. 从 `index+1`（`previous()` 为 `index-1`）起逐项 `checkResourceIsReachable` 懒校验：失效项**立即从 `items` 移除**并继续沿同方向找下一个有效项（首尾回绕；探测预算 = 进入时的图集大小，最多探一轮），未探测到的失效项留到下次校验。**被移除项在当前张之前时，当前张下标同步前移一位**——否则下标会指向被删项，下一轮又按原位前进而跳过紧邻的有效图。
2. 更新 `index` → 触发 `displayState.load(item)`。
3. `ImageLoader.preload(items: at: ±1)`。
4. 若 `items` 被清空 → 切空态页。

### 2.3 ImageLoader（Service）

```swift
actor ImageLoader {
    enum LoadResult { case thumbnail(CGImage), full(CGImage), failed(Error) }
    // full 也返回 CGImage：NSImage 不是 Sendable，不能跨 actor 边界返回

    func thumbnail(for url: URL, maxPixel: CGFloat) async -> CGImage?
    // CGImageSourceCreateThumbnailAtIndex(kCGImageSourceCreateThumbnailFromImageAlways)
    // kCGImageSourceThumbnailMaxPixelSize 是**长边像素**（非百万像素）：
    // 取视图长边 × screen backingScale，与视图尺寸匹配即可

    func fullImage(for url: URL) async throws -> CGImage
    // CGImageSourceCreateImageAtIndex；解码上限 50MP（像素总数）：
    // 超过则用 CGImageSourceCreateThumbnailAtIndex 降采样——注意该 API 参数是
    // **长边像素**，需先按宽高比换算：longEdge = sqrt(50_000_000 × (max(w,h)/min(w,h)))
    // （正方形 ≈ 7071，3:2 ≈ 8660），把 longEdge 传给 ThumbnailMaxPixelSize。
    // 避免一张 100MP 图（~400MB RGBA）撑爆内存。裁剪导出时绕过此上限、重新读原文件
}
```

- 内存缓存 `NSCache<NSURL, CGImage>`（cost = 字节数，**总上限 512MB**：须容得下一张 50MP 全图 ≈200MB，加上预加载相邻 ±1 的余量；NSCache 在超限/内存压力下**自动驱逐**（不承诺具体顺序），超限只是丢缓存重读盘，不影响正确性）。GIF/动图 WebP 例外：直接交给 `NSImageView` 播放，不缓存帧。

- **EXIF 方向**：`CGImageSourceCreateThumbnailAtIndex` / `CGImageSourceCreateImageAtIndex` 默认**不应用** EXIF orientation，竖拍 JPEG/HEIC 会横躺。缩略图加载用 `kCGImageSourceCreateThumbnailWithTransform: true`；全图走 `CGImageSourceCreateImageAtIndex` 后，从 image source 属性字典读 `kCGImagePropertyOrientation`，对 CGImage 做对应的仿射变换转正，保证**显示与导出使用同一套转正逻辑**——否则"显示未转正、导出已转正"会导致裁剪选区与导出结果错位。

### 2.4 删除：FileTrasher（Service）

```swift
enum FileTrasher {
    static func trash(_ url: URL) throws {
        var coordinatedURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &coordinatedURL)
    }
}
```

调用点在 `GalleryViewModel.trashCurrent()`，流程：

1. 记录 `nextTarget`（先算后删）：`items.count > 1 ? (index+1 < items.count ? index : index-1) : nil`；`nil` 表示删完进空态，**必须先判空再算**，否则单图目录会算出 `index-1 = -1`。
2. `try FileTrasher.trash(url)`，按失败原因分支：
   - **成功** → 从 `items` 移除、`index = min(nextTarget, items.count-1)`、toast「已移到废纸篓：文件名」。
   - **文件已不存在**（`NSFileNoSuchFileError` 等）→ 从 `items` 移除并跳下一张，toast「文件已不存在：文件名」。
   - **占用/权限失败**（文件仍在磁盘上）→ **留在当前张**，toast 报错带文件名。禁止把还在盘上的文件移出图集，避免用户误以为已删除。
3. 空态：`items.isEmpty` → 视图层切 `EmptyStateView`。

> 说明：删除的权限兜底见 2.1 的 TCC 引导策略（枚举目录遇拒绝弹 NSOpenPanel）。

### 2.5 裁剪：CropSession + CropOverlayView

#### 状态

```swift
struct CropSession {
    var rectInView: CGRect          // 选区（图片文档坐标系：缩放后文档视图坐标，y 向下；
                                    // 文档 origin 恒为 0，选区 = 像素坐标 × scale）
    var anchor: Handle?             // 正在拖动的手柄 / .move / nil

    init(imageRectInView: CGRect) {
        // 进入裁剪模式时生成默认选框：覆盖图片文档区 100%（全选）
        self.rectInView = imageRectInView
    }

    func pixelRect(scale: CGFloat, imageSize: CGSize) -> CGRect
    // 图片文档坐标 → 图像像素坐标：pixel = rectInView / scale，clamp 到图像边界并取整
    // （imageSize 为 EXIF 正向化后的原图尺寸，经 ImageMetadata.pointSize 读取，
    //   不依赖可能 >50MP 降采样的显示图）

    static func remapped(rect: CGRect, from old: CGRect, to new: CGRect) -> CGRect
    // 窗口尺寸变化时把选区从旧图片显示区按比例映射到新显示区：
    // 保持相对图片的位置与比例，100% 全选映射后仍是 100% 全选（纯函数，可单测）
}

enum Handle { case topLeft, top, topRight, left, move, right, bottomLeft, bottom, bottomRight }
```

#### 交互（CropOverlayView : NSView）

进入裁剪模式即渲染默认选框（**覆盖图片 100% 区域**），用户**通过拖拽线框缩小/移动完成选取**，不支持从空白处拖出新框：

| 事件 | 行为 |
|---|---|
| `mouseMoved` | **可拖拽区域悬停反馈**（NSTrackingArea）：悬停手柄 → 光标变化（角→十字、边→双向箭头）且手柄高亮放大（强调色 18pt vs 常态白色 14pt）；悬停选区内部 → 小手光标；离开 → 恢复箭头 |
| `mouseDown` | 命中 8 个手柄之一（热区 12pt、**只向选区内侧认**，外扩 3pt 容差）→ 进入 resize；命中选区内部 → move（握拳光标）；命中选区外部 → 无操作（不改选区） |
| `mouseDragged` | 按 anchor 更新 `rectInView`；选区最小 10×10pt；`move` 模式 clamp 在图片显示区域内 |
| `mouseUp` | anchor = nil，按落点恢复悬停态 |
| 绘制 | ① 背景画原图灰化快照 ② 选区外用 4 个 0.55 黑 alpha 矩形遮暗 ③ 选区 1.5pt 白边 + 三分线 ④ 8 手柄（悬停/拖动高亮） ⑤ 右下角实时像素尺寸文字 |

> **热区内收的原因**：默认 100% 全选时手柄贴着窗口边缘，若热区向外生效，想拖手柄会误拖窗口、想拖窗口会误改选区；内收后"光标变化 + 手柄高亮"给出明确的可拖拽信号，外侧点击留给窗口缩放。

**选区随缩放/窗口自适应**：裁剪 overlay 是图片文档视图的子视图，选区使用**图片文档坐标**（随滚动/缩放移动）；缩放或窗口尺寸变化时由 `GalleryViewModel` 用 `CropSession.remapped` 按新旧文档尺寸等比重映射（缩放换算见 2.6 缩放策略），选区相对图片不漂移，滚动条存在时也可正常拖拽与保存。

**裁剪入口守卫**：`GalleryViewModel.startCropping()` 依次检查——当前项存在且在支持格式白名单内、非动图（UTI `public.gif` 或动图 WebP：frame count > 1）、无解码错误（当前显示为错误占位页）、图像与原始尺寸均已就绪（`displayState.image != nil && originalImageSize != nil`）。任一不满足即不进入裁剪：**动图单独给反馈**（toast「动图暂不支持裁剪」），其余静默返回（画面已是错误占位页或尚未加载完，与 `W` 键在不支持格式上的静默守卫同一策略）。标题栏裁剪按钮的置灰与入口守卫**共用同一判据**（`canStartCropping`）——加载中 / 解码错误 / 不支持格式 / 动图一律置灰，不出现「按钮亮着但按下去没反应」。

#### 保存导出：CropExporter（Service）

```swift
enum CropExporter {
    static func export(source: URL, pixelRect: CGRect) throws -> CGImage
    // CGImageSource → cgImage.cropping(to: pixelRect)
    // 按 EXIF orientation 先正向化再裁剪，避免方向错乱

    static func suggestURL(for source: URL, in directory: URL) -> URL
    // 命名规则：原名 + " (n)"，序号与原图在 Finder 中排序紧挨
    //   photo_001.jpg → photo_001 (2).jpg → photo_001 (3).jpg ...
    // n 从 2 起，用 FileManager.fileExists 逐个探测，跳过已存在的名字

    static func write(_ image: CGImage, basedOn source: URL) async throws -> URL
    // **直接保存**：不弹 NSSavePanel，目的地 = suggestURL（原图同目录、自动跳过已存在）
    // 写盘质量策略（维持原格式，不转格式）：
    //   PNG/TIFF/BMP → 对应无损编码（比特级无损）
    //   JPEG → kCGImageDestinationLossyCompressionQuality = 1.0（最高质量重编码，
    //          受 JPEG 有损格式本身限制，无法比特级无损；压缩域无损裁剪列为 v0.2 增强）
    //   HEIC → 系统最高质量重编码
    //   WebP → macOS 14+ 按原格式写回（无损 WebP 无损写、有损 WebP 最高质量）；
    //          macOS 13 系统不支持 WebP 编码 → 降级输出 PNG：保存文件名同步改 PNG
    //          扩展名（photo_001.webp → photo_001 (2).png），并 toast 说明，
    //          避免出现"扩展名 .webp 内容却是 PNG"的文件
    // CGImageDestination 写盘 → 返回 URL，ViewModel 发成功 toast
    // 成功后由 ViewModel 将新文件插入 items（原图之后），不自动跳转
}
```

- **直接保存，无另存面板**：目的地恒为 `suggestURL`（原图同目录、`原名 (n)` 自动跳过已存在）。**写盘成功后自动退出裁剪模式**（`mode = .viewing`），toast「已保存：photo_001 (2).jpg」；写盘失败留在裁剪模式、toast 报错（选区保留）。
- **保存规则**：选区未调整（仍是 100% 全选）时按保存**允许执行**——保存整图副本是合法用途；原图不动、新文件可删，无需确认（与"删除不确认"同一效率原则）；不弹"选区为空/未调整"之类的拦截框。
- **单图边界**：目录只剩一张图时删除它，`nextTarget` 计算前先判 `items.count`，避免算出 `index-1 = -1`；删除成功后 `items` 为空 → 直接进空态页。

### 2.6 View 层

```
ContentView (SwiftUI)
├── ImageCanvasView (NSViewRepresentable → CanvasScrollView: NSScrollView)
│     文档视图（isFlipped）承载图片：静图 → CALayer.contents；
│     GIF/动图 WebP → 内嵌 NSImageView（⚠️ 动图 WebP 能否被 NSImage 当动画播放**待实测**；
│                       若只显示首帧，fallback：CVDisplayLink/Timer + ImageIO 逐帧自绘）
│     完整预览：文档视图恒等于可视区（结构上不可能出滚动条），图片以 CALayer
│     在文档内居中绘制；占满宽度：文档 = 图片尺寸（宽度铺满），高度超出部分出
│     竖向滚动条（autohide），文档小于可视区时由 CenteringClipView 居中；
│     切图/切模式滚回文档起点（阅读顺序，两模式互不带入滚动状态），
│     占满宽度下窗口尺寸变化保持可视中心
│     CropOverlayView 是文档视图的子视图，mode == .cropping 时显示
│     （选区 = 图片文档坐标，随滚动/缩放移动，见 2.5）
├── .toolbar（标题栏右侧，与全屏按钮同一区域，参考 Mac 预览）
│     viewing：⛶ 视图切换、🗑 删除、✂ 裁剪 ｜ cropping：💾 保存、✕ 退出
│     不单设工具栏区域；无 ←/→ 按钮，切换仅键盘快捷键
├── ToastView              底部浮层
└── EmptyStateView / ErrorStateView
```

**键盘处理**：`NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 统一分发，按 `mode` 决定路由（viewing：`→` 下一张、`←` 上一张、`⌫` 删除、`C` 裁剪、`W` 切换视图；cropping：`Enter` 保存、`Esc` 退出、方向键微调选区 1pt、Shift+方向 10pt、`W` 切换视图，**其余按键一律不响应**）。**不提供 Space 切换**（长键程费力，PRD FR-2 决策）。

> ⚠️ **修饰键过滤的坑**：方向键的 NSEvent 天然带 `.function` + `.numericPad` 标记（`modifierFlags` rawValue 含 0xA00000），若用 `deviceIndependentFlagsMask` 做"放行组合键"判断会把方向键误判为系统组合键直接放行，快捷键全部失灵。修饰键白名单只能交集 `.shift / .control / .option / .command` 四项。

**模态面板守卫**：local monitor 在 NSOpenPanel（TCC 引导 / 打开其他文件夹）模态期间**仍会收到事件**（面板开着按 `⌫` 会误删图、Esc 会误触路由）。分发前必须先判守卫：`NSApp.modalWindow != nil` 或 `event.window` 不是主图片窗口时，**直接放行、不进入路由**。

**外观**：图片区深色背景 + 内容 `colorScheme = .dark`；窗口 chrome（标题栏/工具栏背景、图标、标题文字）**跟随系统外观**——不给 `NSWindow.appearance` 强制 darkAqua，否则标题栏变暗、与 Mac 预览不一致。

**窗口尺寸策略**（PRD FR-5）：**窗口固定 1:1 正方形，打开与切换图片均不改变窗口大小，不记忆、不还原用户调整**——

- `contentAspectRatio = 1:1`（比例锁定：拖拽调整窗口始终为正方形）、`contentMinSize = 480×480`；
- 初始正方形：边长 = min(屏幕 `visibleFrame` 宽 −36pt, 可用高 −87pt)（近满高），在可用区内居中，仅在窗口首次 resolve 时设置一次；
- 窗口不变 ≠ 裁剪失效：裁剪选区随画布尺寸变化按比例 remap（见 2.5 自适应）。

**视图模式**（PRD FR-1，`Support/ZoomPolicy.swift` 纯函数，可单测）：`scale` = 图片 1px 对应的点数（1.0 = 100%，1px = 1pt）。两种模式，不提供无级缩放：

- **完整预览（fit）**：整张图 fit 进可视区，不超 100%（小图不放大，放大不增加信息量）；文档视图恒等于可视区、图片居中绘制，**无滚动条**。
- **占满宽度（fillWidth）**：图片宽度铺满可视区（可超 100%，封顶 8 倍），高度超出部分竖向滚动——长截图阅读模式。
- **默认模式**：巨高图（高/宽 ≥ 3，长截图）默认占满宽度，其余默认完整预览；巨宽图（全景）不做特殊优化。`W` 键/标题栏按钮切换，切换图片重置为该图默认模式。
- **跟随窗口**：两种模式都随窗口尺寸变化重算缩放（fit 重排 / 宽度始终铺满）；首次布局回调同样按当前模式重算，天然覆盖"打开时可视区未知"的情形。
- **滚动**：切图/切模式滚回文档起点（阅读顺序，两模式互不带入滚动状态）；占满宽度下窗口尺寸变化保持可视中心。
- **原始尺寸**：`Support/ImageMetadata.pointSize`（ImageIO 属性，EXIF orientation 5–8 交换宽高）读取，与可能 >50MP 降采样的显示图解耦；裁剪换算（`pixelRect(scale:imageSize:)`）以此为基准，视图模式/降采样都不影响导出正确性。

## 3. 关键时序

### 3.1 打开图片

```
Finder 右键→打开方式→tidy
  → AppDelegate.application(_:open: urls)      // 可能是多张、可能含 RAW 等白名单外格式
  → GalleryViewModel.open(urls)
      白名单过滤 → 全部不支持? → 错误占位页「不支持的图片格式」，结束
      枚举目录图片 → items 建好, index 定位
        ├ TCC 拒绝 → NSOpenPanel 引导 → 选中: 重建图集 / 取消: 图集仅含被打开文件 + toast
      ImageLoader.thumbnail() → 先渲染缩略图（失败则画布留空）
      ImageLoader.fullImage() (async) → 缓存后替换
        ├ 全图失败(损坏) → 丢弃缩略图 + 错误占位页，可继续切换（裁剪入口随之关闭）
  → 标题更新 "目录名 — photo_001.jpg (3/24)"
```

### 3.2 删除（免确认）

```
点击 🗑 / 按 ⌫ → vm.trashCurrent()
  → 计算 nextTarget → FileTrasher.trash(url)   // 系统直接进废纸篓，无回调确认
  → 成功: items.remove / index=nextTarget / toast「已移到废纸篓：文件名」
  → 文件已不存在: items.remove / 跳下一张 / toast「文件已不存在：文件名」
  → 占用/权限失败: 留在当前张 / toast 报错（带文件名）   // 文件还在盘上，不移出图集
```

### 3.3 裁剪另存

```
✂ 或 C（非 GIF/动图 WebP，否则 toast「动图暂不支持裁剪」）
  → mode=.cropping(CropSession(默认选框=图片 100% 全选))
拖拽线框（手柄/整体移动）→ rectInView 实时更新 → 遮罩重绘 + 尺寸提示
（窗口尺寸变化 → updateCanvasSize → remapped 按比例自适应）
标题栏保存按钮 / Enter → pixelRect(scale:imageSize:) 换算（文档坐标 ÷ scale，与缩放/滚动无关）
  → CropExporter.export() → suggestURL(原名 (n).jpg，跳过已存在)
  → 直接写盘（不弹另存面板；macOS 13 WebP 降级 PNG + toast）
  → mode=.viewing（自动退出裁剪模式）+ 新文件插入 items（原图之后，不跳转）
  → toast「已保存：photo_001 (2).jpg」
```

## 4. 工程结构

SwiftPM 单 executable target（`swift-tools-version:5.8`，platforms `.macOS(.v13)`），零第三方依赖：

```
Package.swift
Sources/tidy/
├── App/            TidyApp.swift, DocumentOpener, ServiceReceiver, KeyHandler
├── ViewModel/      GalleryViewModel, CropSession, ImageDisplayState
├── Views/          ContentView, ImageCanvasView, CropOverlayView,
│                   ToastView, EmptyStateView, WindowAccessor
├── Services/       ImageLoader, FileTrasher, CropExporter, DirectoryScanner
└── Support/        Extensions, Constants, OrientationNormalizer, ZoomPolicy, ImageMetadata
Tests/tidyTests/    DirectoryScannerTests, CropSessionTests, CropExporterTests,
                    FileTrasherTests, GalleryViewModelTests, ImageLoaderTests,
                    ZoomPolicyTests
Resources/          Info.plist（CFBundleDocumentTypes / NSServices 声明）、AppIcon.icns（应用图标）
scripts/            bundle.sh（swift build -c release → 组装 tidy.app）、
                    dmg.sh（bundle → 读写 dmg 内用 AppleScript 摆安装窗口：双分辨率
                    background.tiff（72/144dpi，Retina 下箭头不糊）、图标 64 对位
                    {130,188}/{410,188}、窗口 540×380、隐藏工具栏、卷宗名
                    tidy {版本}-{arch}、卷宗图标，再转 UDZO 只读压缩；未签名/未公证）
```

> Info.plist 对 SPM 可执行文件不生效，需经 `scripts/bundle.sh` 组装 .app 后声明才起作用。

## 5. 测试要点

| 层 | 用例 |
|---|---|
| DirectoryScanner | 自然排序、UTI 白名单（排除 RAW/SVG）、跳过隐藏文件、空目录、权限异常分支 |
| CropSession 坐标 | 默认选框为图片 100% 全选、非整数 scale、放大/缩小显示（scale 1/0.2/2）、选区越界 clamp、10×10pt 下限、EXIF 旋转图（90°/180°）换算正确、**缩放/窗口变化 remapped 比例映射（全选仍全选、空旧区守卫）** |
| ZoomPolicy | fit 模式：大图 = fit、小图 = 100% 不放大；fillWidth 模式：宽度铺满（可超 100%）、极窄图封顶 maxScale；默认模式：巨高图（高/宽 ≥ 阈值）= fillWidth、普通/竖构图/巨宽图 = fit；非法尺寸不崩溃 |
| CropExporter | suggestURL 命名：原名 → ` (2)` → ` (3)`、跳过已存在文件；动图拒绝裁剪；EXIF 方向正确；macOS 13 WebP 降级 PNG |
| FileTrasher | 正常删除、文件已不存在（移除并跳下一张）、占用/权限失败（留在当前张）、空态 |
| GalleryViewModel | 切换：首尾循环、跳过失效项（回绕、连续失效过半仍命中有效项）、全部失效进空态、裁剪态不切图；裁剪入口：不支持格式 / 动图 / 解码错误态 / 图像未就绪均置灰且 `C` 无效，就绪且非动图可进入 |
| ImageLoader | HEIC/GIF/WebP 解码、损坏文件 failed 分支、缓存命中、>50MP 降采样、**竖拍 EXIF 方向显示转正** |
| 手动验收 | PRD 中各 FR 的验收标准逐条过 |

## 6. 实施顺序（对应里程碑）

1. **M1**：App 骨架 + DocumentOpener + ImageCanvasView(fit) + ImageLoader 两级加载 —— FR-1
2. **M2**：DirectoryScanner + GalleryViewModel 切换 + 键盘分发 + 预加载 —— FR-2
3. **M3**：FileTrasher + toast + 空态 —— FR-3
4. **M4**：CropOverlayView + CropSession + CropExporter + SavePanel —— FR-4
5. **M5**：Services 声明、图标、窗口尺寸策略、错误态打磨 —— FR-5
6. **M6**：签名公证（dmg 打包已由 `scripts/dmg.sh` 完成：bundle → hdiutil，含 /Applications 拖装软链；未签名/未公证，仅供信任来源分发，他人机器首次打开需右键 → 打开）

## 7. 已定决策与风险

| 决策 | 说明 |
|---|---|
| 免确认删除 | 仅走废纸篓（可恢复），这是免确认的安全前提；未来若加"永久删除"必须二次确认（PRD 已列为非目标）。 |
| 裁剪坐标 | 核心风险点是视图→像素换算与 EXIF 方向，已设计纯函数 `pixelRect` / `remapped` 便于单测覆盖。 |
| 无沙盒但有 TCC | 非 App Store 分发不开 App Sandbox，但桌面/文稿/下载仍受隐私同意约束；枚举目录遇 TCC 拒绝时用 NSOpenPanel 引导用户选目录（见 2.1），这是整理场景的关键兜底。 |
| 内存策略 | 解码上限 50MP（约 200MB RGBA）、缓存上限 512MB（容得下一张全图 + 预加载余量，超限自动驱逐），只保证有界、不设硬性 SLA；裁剪导出绕过解码上限重新读原文件，保证导出分辨率不受渲染降采样影响。 |
| WebP 编码 | macOS 13 系统无 WebP 编码器，裁剪保存降级 PNG + toast（保存文件名同步改 PNG）；macOS 14+ 原格式写回。 |
| 动图 WebP 播放 | NSImage 对动图 WebP 的动画支持未验证，标记待实测；不动画则 fallback Timer + ImageIO 逐帧自绘（见 2.6）。 |
| open 事件路由 | `CFBundleDocumentTypes` 只是声明；实际打开走 `NSApplicationDelegate.application(_:open:)`；单窗口用 SwiftUI `Window`（macOS 13+，该场景本身不生成 ⌘N，无需处理）。 |
| 超大图 | 渲染走 50MP 降采样；裁剪导出绕过上限重新读原文件（见内存策略）。 |
| 窗口尺寸 | 固定 1:1 正方形、比例锁定、最小 480×480、初始近满高居中（见 2.6）；打开/切换均不改变窗口，不记忆用户调整。无 Space 切换（长键程费力）。 |
| 视图模式 | 只有完整预览 / 占满宽度两种，不做无级缩放（`+`/`-`/`0`/`F` 已移除）；巨高图（高/宽 ≥ 3）默认占满宽度，巨宽图不做特殊优化；窗口 1:1 锁定后视图切换只改变图片文档尺寸，超出部分由竖向滚动条承载；切图重置视图并滚回文档起点；裁剪选区用图片文档坐标，视图切换/滚动不影响导出（见 2.6 视图模式）。 |
