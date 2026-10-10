# Luma

**为 macOS 打造的原生 Emby 客户端。**

Swift · AppKit · AVKit · libmpv

Luma 0.3.3 使用系统原生窗口、侧边栏、工具栏和媒体网格，在 macOS 26 及更新系统中采用 Liquid Glass。macOS 应用不依赖 WebView、Node.js、Tauri 或 Rust。仓库名为 `lumo`，应用名称为 **Luma**。

## 功能

- 浏览电影、剧集、最近添加和继续观看，支持搜索、收藏及分页。
- 自动恢复上次连接；访问令牌保存在 macOS 钥匙串，密码本身不保存。
- 系统兼容媒体使用 AVPlayer / AVKit；MKV 等媒体使用内嵌 libmpv 直接解码播放，无需先转换文件。
- libmpv 请求 VideoToolbox 硬件解码，支持音轨、字幕、倍速、跳转、全屏和续播。
- 原生媒体键与“正在播放”，同步 Emby 播放进度；AVKit 路线支持系统画中画。
- 支持系统深浅外观、键盘快捷键、平滑滚轮和远程控制下的滚轮速度调整。
- 海报按显示尺寸缩小，合并重复请求，使用有界内存缓存和并发下载。

这是持续开发中的客户端，尚未提供离线下载、Emby Connect 或自动更新。libmpv 路线暂不支持系统画中画；HDR 色彩准确性、所有字幕样式和所有 Mac 型号尚未全面验证。Luma 是独立项目，与 Emby、Apple 和 IINA 无隶属关系。

## 从源码构建

当前发布提供源码，不提供预编译安装包。

需要 macOS、Swift 6 或更新工具链、**macOS 26 或更新 SDK**、Python 3.10+ 与 Homebrew。SDK 版本决定能否编译 Liquid Glass 接口。最近一次本地验证环境为 Apple Silicon、macOS 27、Swift 6.4。

源码保留 macOS 13 部署目标与旧系统界面回退，但**生成应用的最低系统版本取决于实际链接的 libmpv 及依赖**。打包脚本会自动计算；本地已验证的依赖要求 macOS 27。旧系统和 Intel 构建需要兼容依赖，并另行验证。

```sh
git clone https://github.com/carelessty/lumo.git
cd lumo

# 安装 Xcode 或 Command Line Tools 后，确认当前 SDK 至少为 26
xcrun --sdk macosx --show-sdk-version
swift --version
python3 --version

brew install mpv pkgconf ffmpeg
./scripts/test-macos.sh
./scripts/run-macos.sh
```

应用生成于 `build/macos/Luma.app`。需要安装到“应用程序”时，将它复制到 `/Applications`。

```sh
# 单独构建与归档
./scripts/build-macos.sh
./scripts/archive-macos.sh

# 调试构建
LUMA_BUILD_CONFIGURATION=debug ./scripts/run-macos.sh
```

脚本默认以 Release 构建，将实际需要的非系统动态库装入应用，重写加载路径并执行本地 ad-hoc 签名。构建后的应用无需从 Homebrew 路径加载库；它尚未经过 Developer ID 签名或公证。测试使用 FFmpeg 命令行程序生成媒体夹具，正常 libmpv 播放不启动 FFmpeg 子进程。

## 连接与使用

启动后可浏览演示资料库，或填写自己的 Emby 服务器地址、用户名和密码。地址示例：`http://192.168.1.10:8096`、`https://media.example.com`。反向代理有路径前缀时应保留，不要填写 `/web/index.html` 页面地址。

连接成功后，应用将连接信息与访问令牌存入登录钥匙串，重启时自动恢复。侧边栏“管理连接…”可以切换服务器；“断开并忘记”清除保存的会话。临时离线会保留连接信息。UserDefaults 保存设备标识、上次服务器与用户名和偏好；网络图片仅缓存在内存中。

| 操作 | 快捷键 |
| --- | --- |
| 连接服务器 | ⌘K |
| 搜索 | ⌘F |
| 刷新 | ⌘R |
| 切换主要资料库 | ⌘1–4 |
| 设置 | ⌘, |
| 查看影片详情 | 回车或双击 |
| 播放 / 暂停 | 空格 |
| 播放中前后跳转 15 秒 | ← / → |

无手势阶段的鼠标滚轮输入使用平滑滚动，触控板手势与系统惯性沿用 AppKit。如果远程桌面注入的滚轮移动过大，可在“设置 → 滚轮速度”选择“较慢 · 适合远程”；默认是原始速度。开启系统“减弱动态效果”会停用额外滚动动画。

演示资料库使用虚构片名和项目生成的图片；播放的是 Blender Foundation 的 Sintel 在线预告片，需要联网，不是所选虚构影片的正片。见[素材说明](docs/assets.md)。

## 播放架构

| 媒体路径 | 引擎 |
| --- | --- |
| 系统兼容的 MP4 / MOV / HLS | AVPlayer / AVKit |
| MKV、受支持的 DTS / TrueHD / FLAC 等媒体 | 内嵌 libmpv 直接播放 |
| 无兼容原流，且服务器允许转码 | AVPlayer 播放服务器提供的 H.264 / AAC HLS |

libmpv 通过公开 C API 与 AppKit 集成，使用 OpenGL render API 和 VideoToolbox。硬件解码能否启用取决于芯片和编码；实际启用后播放器才显示“硬件解码”。当前实现不是 Metal 渲染，也未宣称端到端零拷贝。IINA 是架构参考，没有复制其应用二进制或界面源码。

旧 `LocalPlaybackBridge` 转换实现及测试保留供兼容回退开发使用，当前自动协商不会为 MKV 选择它。更详细的网络、会话和播放边界见[架构说明](docs/native-architecture.md)。

## 工程与开发

```text
macos/Sources/Luma/     AppKit 界面、网络、会话与双播放器
macos/Sources/CMPV/     libmpv C API 桥接
macos/Tests/LumaTests/  Swift Testing 测试
scripts/               构建、测试、归档与本地模拟服务器
public/media/          演示图片
src/                   旧版 React 界面
src-tauri/             实验性 Windows 客户端
```

[开发说明](docs/development.md)包含本地模拟服务器、测试、贡献方式和 Windows 实验版构建方法。GitHub Actions 检查原生 macOS 与实验性 Windows 构建；目前不上传应用或安装包。

## 许可证

Copyright (C) 2026 Luma contributors.

本项目原创代码与随仓库分发的原创资源采用 **GNU General Public License v3.0 or later**（`GPL-3.0-or-later`）：你可以根据 GNU GPL 第 3 版，或自行选择的更新版本，使用、修改和再分发。本项目不提供任何担保。完整条款见 [LICENSE](LICENSE)。

第三方库及在线演示视频保留各自许可证。libmpv/FFmpeg 的许可取决于实际构建配置；发布链接这些库的二进制时，还需提供与该构建匹配的对应源码和许可材料。参见[第三方依赖说明](macos/ThirdPartyNotices.md)及 [mpv 官方许可说明](https://github.com/mpv-player/mpv/blob/master/Copyright)。
