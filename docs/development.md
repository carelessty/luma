# 开发与贡献

macOS 主工程使用 SwiftPM、AppKit 和 Swift Testing。请先按根目录 README 安装 SDK 与 Homebrew 依赖。

## 检查

```sh
./scripts/test-macos.sh
./scripts/build-macos.sh
./scripts/archive-macos.sh
```

测试脚本自动定位 Swift Testing，并将测试构建放在临时目录以避免 FileProvider 元数据影响签名。可用 `LUMA_TEST_SCRATCH` 指定目录。测试应以 Swift Testing 的完整通过汇总为准，而不只查看进程退出码。播放测试使用本机合成媒体，需要 FFmpeg；部分验证涉及 AppKit 窗口与硬件解码，因此应在有图形会话的 Mac 上运行。

构建脚本计算动态库闭包、核对架构和最低系统版本，装入依赖及其许可证。归档脚本重新解压并验证代码签名。GitHub Actions 执行检查和打包验证，但不对外上传二进制。

## 本地模拟服务器

无需真实账户即可联调登录、首页、分页、收藏、详情与进度上报：

```sh
node scripts/mock-emby.mjs
```

从应用连接 `http://127.0.0.1:8097`，使用演示用户名 `demo`、密码 `demo`。该服务只监听本机，包含虚构资料，所有状态在进程退出后消失。`http://127.0.0.1:8097/__qa/state` 提供本地检查状态。按 Ctrl+C 停止。

默认视频来自 Sintel 在线预告片，首次播放需要联网。此夹具不是生产 Emby Server，不能替代真实服务器、反向代理、媒体格式和设备兼容性测试。高级夹具选项见 `scripts/mock-emby.mjs`。

## 保留的 Windows 实验版

`src/` 和 `src-tauri/` 是早期 React + Tauri / Rust 实现，与 macOS AppKit 工程独立。需要 Node.js 22+、Rust stable（至少 1.90），Windows 构建还需要 Visual Studio C++ Build Tools 与 WebView2。

```sh
npm ci
npm test
npm run build
cargo fmt --manifest-path src-tauri/Cargo.toml --check
cargo test --manifest-path src-tauri/Cargo.toml --locked
cargo clippy --manifest-path src-tauri/Cargo.toml --locked --all-targets -- -D warnings

# 在 Windows 上运行或生成安装包
npm run desktop:dev
npm run desktop:build -- --bundles nsis
```

旧版界面预览可运行 `npm run dev`。浏览器预览主要展示演示模式；真实服务器请求由 Tauri 原生后端处理。请勿把旧版网页或 Tauri 预览当作当前 macOS AppKit 应用。

## 提交问题与改动

欢迎通过 GitHub Issues 和 Pull Requests 提交复现步骤、修复与改进。请说明系统、芯片、应用版本，以及问题发生在哪个播放器或界面流程；改动应包含与其风险相称的验证说明。贡献按项目 GPL-3.0-or-later 许可提交。

请使用模拟数据和脱敏截图，不要提交服务器密码、访问令牌、带认证参数的播放链接或个人观看记录。本地联调记录、截图、输入采样、构建产物和缓存默认不进入仓库；需要新增公开文档时，在 `.gitignore` 的文档白名单中显式加入。
