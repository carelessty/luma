# 素材与第三方归属

## 项目素材

`public/media/hero.jpg` 与六张 `poster-*.jpg` 是为本项目生成的虚构演示图片，使用 OpenAI 图像生成工具制作；对应片名和资料均为演示内容，不代表真实电影或服务器资料库。这些随仓库提供的项目素材适用根目录所述 GPL-3.0-or-later 许可。

应用图标采用项目自绘的几何播放符号，矢量来源为 `src-tauri/icons/source.svg`；原生 macOS 图标位于 `macos/Resources/AppIcon.icns`。网页 favicon 为 `public/favicon.svg`。

## 在线演示视频

演示播放链接指向 W3C 托管的 **Sintel 预告片**，视频不包含在本仓库中。

- 作品：Sintel
- 制作与版权：© Blender Foundation | durian.blender.org
- 许可：Creative Commons Attribution 3.0（CC BY 3.0）
- [官方分享与许可说明](https://durian.blender.org/sharing/)
- [CC BY 3.0 条款](https://creativecommons.org/licenses/by/3.0/)
- [演示视频来源](https://media.w3.org/2010/05/sintel/trailer.mp4)

视频仍按其原许可提供，不适用项目 GPL 许可。连接真实服务器后，封面与影片来自用户的 Emby 服务器，不包含在仓库或应用资源中。

## 代码依赖与系统图标

macOS 应用使用 AppKit 系统控件和 SF Symbols 系统符号，符号由系统提供。旧版 React 界面通过 `lucide-react` 使用 ISC 许可的 Lucide 图标。Swift、npm 和 Cargo 依赖分别保留上游许可，仓库不包含它们的安装目录或编译产物。

libmpv 及随本地构建装入的动态库见 [ThirdPartyNotices.md](../macos/ThirdPartyNotices.md)。
