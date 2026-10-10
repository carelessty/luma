import AppKit

@main
enum LumaApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?
    private var terminationReplied = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsController.applyAppearance()
        installMenu()
        let controller = MainWindowController()
        mainWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await mainWindow?.stopPlaybackAndWait(); replyToTermination() }
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); replyToTermination() }
        return .terminateLater
    }
    private func replyToTermination() {
        guard !terminationReplied else { return }
        terminationReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.showWindow(nil)
        return true
    }
    private func installMenu() {
        let menu = NSMenu()
        NSApp.mainMenu = menu
        let app = NSMenu(title: "Luma")
        app.addItem(withTitle: "关于 Luma", action: #selector(about), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        let services = NSMenu(title: "服务")
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 Luma", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "退出 Luma", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appendMenu(app, to: menu)
        let file = NSMenu(title: "文件")
        file.addItem(withTitle: "连接服务器…", action: #selector(connect), keyEquivalent: "k").target = self
        file.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appendMenu(file, to: menu)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        appendMenu(edit, to: menu)
        let view = NSMenu(title: "显示")
        view.addItem(withTitle: "搜索资料库", action: #selector(search), keyEquivalent: "f").target = self
        view.addItem(withTitle: "刷新", action: #selector(refresh), keyEquivalent: "r").target = self
        view.addItem(withTitle: "显示或隐藏侧边栏", action: #selector(sidebar), keyEquivalent: "s").target = self
        view.items.last?.keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        for (index, title) in ["现在观看", "电影", "剧集", "收藏"].enumerated() {
            let item = view.addItem(withTitle: title, action: #selector(navigate(_:)), keyEquivalent: String(index + 1))
            item.target = self; item.tag = index
        }
        appendMenu(view, to: menu)
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fullScreen = window.addItem(withTitle: "进入或退出全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        window.addItem(withTitle: "全部置于顶层", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        appendMenu(window, to: menu)
        let help = NSMenu(title: "帮助")
        help.addItem(withTitle: "Luma 使用帮助", action: #selector(showHelp), keyEquivalent: "").target = self
        appendMenu(help, to: menu)
        NSApp.helpMenu = help
    }
    private func appendMenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Luma", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.3", .version: "原生 macOS 版", .credits: NSAttributedString(string: "你的私人影院，与你的 Mac 恰如其分。\nSwift · AppKit · AVKit · libmpv\n\nEmby 客户端，与 Emby 官方无隶属关系。")])
    }
    @objc private func connect() { mainWindow?.showConnect() }
    @objc private func settings() { mainWindow?.showSettings() }
    @objc private func search() { mainWindow?.focusSearch() }
    @objc private func refresh() { mainWindow?.reload() }
    @objc private func sidebar() { mainWindow?.toggleSidebar() }
    @objc private func navigate(_ sender: NSMenuItem) { mainWindow?.selectDestination(sender.tag) }
    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "让好故事，回到眼前。"
        alert.informativeText = "使用 ⌘K 连接你的 Emby 服务器。\n双击海报或按回车查看详情，空格直接播放。\n⌘F 搜索，⌘R 刷新，⌘1–4 切换资料库。\n\nMP4 使用系统播放器，MKV 等格式在应用内直接播放。支持空格暂停、左右键跳转、音轨与字幕选择、倍速和系统媒体键。使用 ⌃⌘F 进入全屏。系统播放器路线还支持画中画。\n\n未连接时显示的是虚构影片预览，播放为 Sintel 示例短片。"
        alert.runModal()
    }
}
