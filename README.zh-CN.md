<p align="center">
  <img src="macos/Resources/AppIcon.svg" width="96" alt="Luma 图标">
</p>

# Luma

使用 Swift 和 AppKit 开发的原生 macOS Emby 客户端。

[![Native macOS checks](https://github.com/carelessty/lumo/actions/workflows/macos-native.yml/badge.svg)](https://github.com/carelessty/lumo/actions/workflows/macos-native.yml)
[English](README.md) · [简体中文](README.zh-CN.md)

Luma 让你在 Mac 上浏览和播放 Emby 媒体库，使用原生界面和系统播放控件，通过 libmpv 支持 MKV 等媒体格式。项目仍在开发中，目前提供源码构建，暂未发布预编译安装包。

## 功能

- 浏览电影和剧集、搜索媒体库、管理收藏、继续观看。
- 使用 AVKit 播放系统支持的媒体，通过 libmpv 播放更多格式，并在可用时使用 VideoToolbox 硬件解码。
- 切换音轨和字幕、调整播放速度，将观看进度同步至 Emby。
- 支持 macOS 媒体键、正在播放、全屏，以及 AVKit 的系统画中画。
- 将连接保存在钥匙串中，启动时自动恢复会话。
- 跟随系统外观和语言，在 macOS 26 及更新版本使用 Liquid Glass。支持英文和简体中文。

尚未实现离线下载、Emby Connect、自动更新，以及 libmpv 播放器的系统画中画。

## 构建

环境要求：

- macOS，安装提供 **Swift 6+ 和 macOS 26+ SDK** 的 Xcode 或 Command Line Tools。
- [Homebrew](https://brew.sh/) 和 Python 3.10+。
- `mpv` 和 `pkgconf`；运行测试还需要 `ffmpeg`。

```sh
git clone https://github.com/carelessty/lumo.git
cd lumo
brew install mpv pkgconf ffmpeg
./scripts/test-macos.sh
./scripts/run-macos.sh
```

生成的应用位于 `build/macos/Luma.app`，复制到 `/Applications` 即可安装。构建脚本会打包所需动态库并进行 ad-hoc 签名，目前未配置 Developer ID 签名和公证。

源码的部署目标为 macOS 13，但**实际应用的最低系统版本取决于所有打包依赖中的最高要求**，由打包脚本自动计算。目前本地验证环境为 Apple Silicon、macOS 27；旧版 macOS 和 Intel 构建需要兼容的动态库，并另行测试。

调试构建、归档和本地测试服务器的使用方式见[开发指南](docs/development.md)。

## 使用

填写 Emby 服务器地址和账户，例如 `https://media.example.com` 或 `http://192.168.1.10:8096`。使用反向代理时保留路径前缀，不要填写服务器的 `/web/index.html` 页面地址。

Luma 启动时会恢复上次会话。通过侧边栏的**管理连接…**切换服务器，或使用**断开并忘记**移除保存的会话。访问令牌保存在钥匙串中，密码不保存。

应用默认跟随 macOS 首选语言。若只想更改 Luma 的语言，可在**系统设置 → 通用 → 语言与地区 → 应用程序**中添加 Luma，选择英文或简体中文，然后重新启动应用。Emby 提供的片名和简介保留服务器所提供的语言。

| 操作 | 快捷键 |
| --- | --- |
| 连接服务器 | ⌘K |
| 搜索 | ⌘F |
| 刷新 | ⌘R |
| 切换资料库分区 | ⌘1–4 |
| 设置 | ⌘, |
| 打开详情 | 回车或双击 |
| 播放 / 暂停 | 空格 |
| 后退 / 前进 | ← / → |

若远程桌面连接下滚动幅度过大，可在**设置 → 滚轮速度**中调低速度。触控板手势沿用系统滚动行为。

## 参与贡献

欢迎提交问题、修复和翻译。提交问题前请先搜索[现有 Issues](https://github.com/carelessty/lumo/issues)，并提供可复现的操作步骤。中文和英文报告均可。

贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)，源码结构见[架构指南](docs/native-architecture.md)。

## 许可证

Luma 采用 [GPL-3.0-or-later](LICENSE) 许可证。第三方库和演示媒体保留各自的许可证，详见[第三方依赖说明](macos/ThirdPartyNotices.md)和[素材归属](docs/assets.md)。

Luma 是独立项目，与 Emby 或 Apple 无隶属关系。
