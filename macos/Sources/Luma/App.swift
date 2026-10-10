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
        app.addItem(withTitle: L10n.ui("menu.about"), action: #selector(about), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: L10n.ui("menu.settings"), action: #selector(settings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        let services = NSMenu(title: L10n.ui("menu.services"))
        let servicesItem = NSMenuItem(title: L10n.ui("menu.services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: L10n.ui("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: L10n.ui("menu.hideOthers"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: L10n.ui("menu.showAll"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L10n.ui("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appendMenu(app, to: menu)
        let file = NSMenu(title: L10n.ui("menu.file"))
        file.addItem(withTitle: L10n.ui("menu.connect"), action: #selector(connect), keyEquivalent: "k").target = self
        file.addItem(withTitle: L10n.ui("menu.closeWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appendMenu(file, to: menu)
        let edit = NSMenu(title: L10n.ui("menu.edit"))
        edit.addItem(withTitle: L10n.ui("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L10n.ui("menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.ui("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.ui("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.ui("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.ui("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        appendMenu(edit, to: menu)
        let view = NSMenu(title: L10n.ui("menu.view"))
        view.addItem(withTitle: L10n.ui("action.searchLibrary"), action: #selector(search), keyEquivalent: "f").target = self
        view.addItem(withTitle: L10n.ui("action.refresh"), action: #selector(refresh), keyEquivalent: "r").target = self
        view.addItem(withTitle: L10n.ui("menu.toggleSidebar"), action: #selector(sidebar), keyEquivalent: "s").target = self
        view.items.last?.keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        for (index, title) in [L10n.ui("navigation.watchNow"), L10n.ui("navigation.movies"), L10n.ui("navigation.shows"), L10n.ui("navigation.favorites")].enumerated() {
            let item = view.addItem(withTitle: title, action: #selector(navigate(_:)), keyEquivalent: String(index + 1))
            item.target = self; item.tag = index
        }
        appendMenu(view, to: menu)
        let window = NSMenu(title: L10n.ui("menu.window"))
        window.addItem(withTitle: L10n.ui("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L10n.ui("menu.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fullScreen = window.addItem(withTitle: L10n.ui("menu.toggleFullScreen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        window.addItem(withTitle: L10n.ui("menu.bringAllToFront"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        appendMenu(window, to: menu)
        let help = NSMenu(title: L10n.ui("menu.help"))
        help.addItem(withTitle: L10n.ui("menu.lumaHelp"), action: #selector(showHelp), keyEquivalent: "").target = self
        appendMenu(help, to: menu)
        NSApp.helpMenu = help
    }
    private func appendMenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Luma", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0", .version: L10n.ui("about.edition"), .credits: NSAttributedString(string: L10n.ui("about.credits"))])
    }
    @objc private func connect() { mainWindow?.showConnect() }
    @objc private func settings() { mainWindow?.showSettings() }
    @objc private func search() { mainWindow?.focusSearch() }
    @objc private func refresh() { mainWindow?.reload() }
    @objc private func sidebar() { mainWindow?.toggleSidebar() }
    @objc private func navigate(_ sender: NSMenuItem) { mainWindow?.selectDestination(sender.tag) }
    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = L10n.ui("help.title")
        alert.informativeText = L10n.ui("help.body")
        alert.runModal()
    }
}
