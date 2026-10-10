import AppKit

extension NSPopUpButton {
    /// Media tracks have stable IDs but may share a display title. The popup's
    /// addItem(withTitle:) removes an existing item with that title, which would
    /// make menu indexes disagree with the corresponding subtitle choices.
    @discardableResult
    func appendTrackItem(title: String, tag: Int = 0) -> NSMenuItem {
        if menu == nil { menu = NSMenu() }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = tag
        menu?.addItem(item)
        return item
    }
}
