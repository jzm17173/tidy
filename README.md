# tidy

极简的 macOS 图片预览整理工具：打开即看清内容，同一窗口内键盘直达删除（进废纸篓、免确认），拖拽线框裁剪另存。

## 文档

| 文档 | 内容 | 地位 |
|---|---|---|
| [需求文档 PRD](docs/tidy-需求文档-PRD.md) | 问题背景、功能需求与验收标准、非功能需求、发布计划 | 需求唯一来源 |
| [详细设计](docs/tidy-详细设计.md) | 架构、模块设计、关键时序、测试要点、实施顺序 | **施工依据**（实现以本文为准） |
| [技术选型与方案](docs/图片预览工具-技术方案.md) | 选型对比与结论 | 仅第 2 节选型有效，功能细节已由详细设计取代 |

## 核心交互

- 右键图片 → 打开方式 → tidy（单实例，再次打开即在窗口内切换目录）
- `→` 下一张，`←` 上一张；`⌫` 直接移到废纸篓（无确认）
- `W` 切换视图：完整预览 / 占满宽度（长截图默认占满宽度，竖向滚动阅读）
- `C` 进入裁剪（默认 100% 全选，拖拽线框调整），`Enter` 直接保存 `原名 (2).jpg` 到同目录，`Esc` 取消

## 构建与开发

SwiftPM 工程（Swift 5.8+ / macOS 13+），零第三方依赖：

```sh
swift build          # 编译
swift test           # 单元测试（DirectoryScanner / CropSession / CropExporter / FileTrasher / ImageLoader / ZoomPolicy）
scripts/bundle.sh    # release 构建并组装 tidy.app（含 Info.plist 声明）
scripts/dmg.sh       # 产出 tidy.dmg（未签名/未公证，他人机器首次打开需右键 → 打开）
```

> 本仓库开发机若只有 Command Line Tools（无 Xcode），`swift build`/`swift test` 需要先执行一次 `scripts/test-env/bootstrap.sh` 并按其提示设置 `DEVELOPER_DIR` 与 `PATH`；有 Xcode 则直接可用。

设计细节与里程碑见 [详细设计](docs/tidy-详细设计.md)。
