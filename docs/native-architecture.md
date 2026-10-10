# Luma 原生 macOS 实现

Luma 的 macOS 目标是独立的 SwiftPM 可执行程序。AppKit 创建真实的 NSApplication、NSWindow、NSSplitViewController、NSToolbar、NSTableView 和 NSCollectionView；没有网页容器、JavaScript 桥接或 Rust FFI。播放器根据媒体选择 AVPlayer 或 libmpv；后者通过 `CMPV` system library 调用公开 C API。旧 Windows 工程保持独立。

| 层 | 实现 | 职责 |
| --- | --- | --- |
| 应用与窗口 | `App.swift`、`MainWindowController.swift` | 菜单、快捷键、窗口生命周期、导航、请求取消和刷新 |
| 原生视图 | `NativeUI.swift`、`SidebarController.swift`、`Sheets.swift` | 可复用媒体网格、侧边栏、登录与详情 sheet、设置 |
| 领域与通信 | `Models.swift`、`Backend.swift` | 类型化界面数据、actor 内会话、URLSession 请求与播放协商 |
| 图像 | `ImagePipeline.swift` | ImageIO 缩略图、请求合并、并发限制、内存缓存 |
| 播放协调 | `PlayerWindowController.swift`、`SubtitleParser.swift` | 引擎选择、AVKit / AppKit 控件、正在播放、字幕、进度上报与清理 |
| 直接播放引擎 | `MPVPlayback.swift`、`Sources/CMPV/` | libmpv 解复用与解码、VideoToolbox、OpenGL 显示、音轨和字幕 |
| 保留的兼容实现 | `LocalPlaybackBridge.swift` | 旧 FFmpeg 视频复制、AAC 转换与本机 HLS；当前协商不默认选择 |
| 演示 | `DemoCatalog.swift` | 明确标识的虚构媒体资料库与 Sintel 在线预告片 |

## Liquid Glass

在 macOS 26+ 使用 `NSButton.bezelStyle = .glass`，首页播放操作采用 `.primary` 着色层级，详情采用 `.none`。按钮作为 `NSGlassEffectContainerView` 的内容共同渲染，由原生按钮保留键盘、焦点和点击行为。工具栏按钮设置 `isBordered = true`，由系统生成玻璃分组。侧边栏继续采用 `NSSplitViewItem(sidebarWithViewController:)`，避免手工叠加材质。旧系统保留 `.rounded` 按钮。没有使用自绘模糊滤镜或循环动画。

## 会话和网络

登录使用 Emby `Users/AuthenticateByName`。服务器地址省略协议时按 HTTP 处理；根地址补上 `/emby/`，显式提供的反向代理路径会保留。API 请求携带 `X-Emby-Authorization` 和 `X-Emby-Token`，API 不自动跟随重定向。图片请求使用独立重定向策略，允许服务器图片路由和 CDN 跳转，跨源时去掉 Emby 凭据，拒绝 HTTPS 降级。HTTPS 使用系统证书校验；应用允许连接用户明确填写的 HTTP 服务器。

`SessionStore.swift` 将访问令牌和连接信息保存在 macOS 登录钥匙串的单条凭据中，密码不保存。启动时恢复会话并通过认证接口验证，临时离线保留凭据，401 删除失效令牌；主动断开清除保存的连接，切换成功才原子替换旧连接。存储失败会显示错误，不假装已经记住连接。UserDefaults 存储设备 ID、上次服务器与用户名、界面和播放偏好、演示收藏。会话代数校验防止旧请求覆盖新账号的结果；登录失效会显示重新连接提示，不把真实资料库悄悄替换成演示内容。

首页并行获取续播、最近添加、电影、剧集和资料库。媒体列表分页请求，搜索有 280 毫秒防抖，主窗口通过请求代数忽略过期结果。图片按目标尺寸解码；缓存预算 96 MiB、160 张，最多 6 个并行下载，缓存不写入磁盘。

首页非认证类局部失败保留其他分区，并显示缺失区域提示。搜索一旦编辑立即使旧分页失效，分页绑定已显示的查询快照。收藏只重绘对应单元而保留滚动位置与键盘选中。封面请求按可见订阅者计数，无人等待时取消下载或排队；旧认证请求的迟到 401 不会清除新会话。

## 播放约定

客户端向 `Items/{id}/PlaybackInfo` 发送 AVPlayer 与 libmpv 合并的能力配置。先选择系统兼容的直接播放来源，再选择 libmpv 可读取的原流，最后才选服务器转码。系统路线包括 MP4 / M4V / MOV / HLS 中的 H.264 或 HEVC 视频，以及可协商的 AAC、MP3、AC-3、E-AC-3、ALAC 音频；实际能否解码仍由媒体细节与系统能力决定。

libmpv 路线在受支持的容器和编码白名单内选择 MKV、WebM、TS 等来源，支持包含 DTS、TrueHD、FLAC、Opus 等音轨的媒体。服务器声明 `SupportsDirectPlay` 时使用原流地址；缺少 `DirectStreamUrl` 时，可按 Emby 标准 `Videos/{id}/stream.{container}` 接口生成地址，不把服务器文件路径当作 URL。只有 DirectPlay 使用 `Static=true`；DirectStream 保留服务器所需的封装处理。未知编码或无可用原流时，要求服务器提供 H.264 / AAC HLS；没有可用路线就给出明确错误。

`MPVPlayback` 持有 libmpv core 与 render context，在独立事件队列处理回调和命令，将状态交给主线程更新原生视图。它显式禁用 mpv 用户配置、脚本、外部 URL 解析器和磁盘缓存。`hwdec=videotoolbox` 请求硬件视频解码，`hwdec-current` 的实际状态用于界面提示；不兼容的编码可能软件解码。OpenGL render API 将画面绘制到 AppKit 的视频视图，没有使用 Metal，也不宣称已验证端到端零拷贝或 HDR 色彩准确性。

这条路径直接解复用与解码，不启动 FFmpeg 子进程、不重新编码音视频，也不写中间转换文件。当前前向 demuxer 缓存上限为 64 MiB、回看缓存 32 MiB、目标缓存时间 30 秒；这些不是应用总内存上限，解码器、渲染器和界面仍占用额外内存。暂停和恢复作用于同一引擎；跳转通过原流精确 seek，实际时延受网络和源文件索引影响。

旧 `LocalPlaybackBridge` 及回归测试保留，便于必要时开发兼容回退，但当前自动协商不会将 MKV 交给它。该旧实现使用 FFmpeg 子进程复制视频、将第一条音轨转 AAC，再生成私有本机 HLS；它与新 libmpv 直接播放路径的资源和性能特征不同。

初始媒体、图片和字幕 URL 需要与服务器同源，才会附加访问令牌。因此，返回其他 CDN 域名作为媒体地址的 Emby 部署暂不支持。不要在日志或问题报告中粘贴完整的已认证播放 URL。

时间单位为 Emby ticks（每秒 10,000,000）。协商从时间零开始：AVPlayer 就绪后定位续播时间，libmpv 在载入时带入起始位置。两个引擎共用有序的开始、进度和停止上报，使用设备与播放会话 ID 清理对应的服务器会话；直接播放不被误报为本地转码。换片与关闭时解绑显示和回调，再在后台释放 libmpv 资源。切换账号等待播放清理；退出最多等待 3 秒，网络不通时仍能退出。

AVPlayer 路线保留系统全屏、画中画以及可用的嵌入音轨 / 字幕。libmpv 路线提供 AppKit 播放/暂停、整片时间轴、音量、0.5～2 倍速和窗口全屏；空格切换暂停，左右键前后跳转 15 秒。工具栏音轨与字幕菜单来自实际解码器轨道列表，支持切换内嵌音轨和字幕；Emby 外部文本字幕可通过 `sub-add` 交给 libmpv。两条路线都接入系统正在播放和媒体键。libmpv 当前不提供系统画中画，章节菜单尚未实现。

AVPlayer 外部 WebVTT 仍使用应用叠加层，该层不进入系统画中画窗口。libmpv 的图形字幕和 HDR 视频可能可解码，但所有字幕样式、HDR 输出及多声道设备尚未完整验证。离线下载、初始跨服务器 CDN URL 和任意编码的无条件兼容不在当前实现范围内。

## 构建和验证

已验证的本地构建产物为 Apple Silicon，最低 **macOS 27**，由 Homebrew mpv 0.41.0 revision 10 bottle 的真实 Mach-O 要求决定。源码仍声明 macOS 13 部署目标并保留旧系统回退，不等于当前应用二进制支持 macOS 13。兼容旧系统或 Intel 需要另一套兼容动态库、重新构建与实测。

本机开发与测试使用 macOS 27 SDK、Swift 6.4，保留 Swift 5 语言模式。没有外部 Swift 包；需要 Homebrew `mpv` 和 `pkgconf` 提供系统库、头文件与 pkg-config 元数据。测试媒体夹具生成使用 FFmpeg 命令行程序。

```sh
brew install mpv pkgconf
./scripts/test-macos.sh
scripts/build-macos.sh
open build/macos/Luma.app
```

Swift Testing 覆盖服务器地址与媒体 URL、认证和资料库请求、演示分页与收藏、引擎路由、进度生命周期、会话取消与过期处理，以及 WebVTT 时间、重叠字幕和无效数据。libmpv 测试使用本机合成媒体检查解码、轨道和播放控制；网络测试使用 URLProtocol 模拟响应。它们不能替代真实 Emby、实际影片和不同显示设备的端到端兼容性测试。

构建脚本使用 native SwiftPM 引擎并核对链接 SDK，将可执行文件、Info.plist、独立原生图标和演示图片装配为 `build/macos/Luma.app`。`bundle-mpv.py` 遍历 Mach-O 非系统动态依赖闭包，复制到 `Contents/Frameworks` 并重写 install name 与 rpath；生成的应用无需从 Homebrew 绝对路径加载这些库。本次闭包为 48 个库、约 60.7 MiB，来源为 41 个 Homebrew 包；未来依赖更新时按实际闭包重新计算。

脚本检查每个库的架构，按所有二进制的最高 minos 更新生成的 `LSMinimumSystemVersion`，逐库签名后签署整个 app。`Contents/Resources/ThirdParty/manifest.json` 及各包子目录保存版本、原始哈希、构建来源、formula 和瓶装包附带的许可证。项目源码以 GPL-3.0-or-later 开源。依赖包含 GPL 组件；本地 ad-hoc 签名构建的公开分发仍需提供匹配的依赖对应源码与许可材料，并另行处理开发者签名和公证。参见 [第三方说明](../macos/ThirdPartyNotices.md)。

归档脚本使用 `ditto` 生成 `build/macos/Luma-macOS.zip`，并重新解压验证签名；没有公证或对外发布步骤。

测试脚本自动定位当前 Swift 工具链的 Testing 宏插件，并将测试构建目录放在系统临时目录，兼容仅安装 Command Line Tools 的环境，也避免 iCloud / FileProvider 给测试包添加 Finder 元数据后导致签名失败。可使用 `LUMA_TEST_SCRATCH` 指定独立构建目录。
