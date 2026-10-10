import AppKit
import Testing
@testable import Luma

@Suite(.serialized)
@MainActor
struct TrackMenuTests {
    @Test
    func repeatedAudioTitlesKeepIndependentTrackIDs() {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let first = popup.appendTrackItem(title: "国语", tag: 2)
        let second = popup.appendTrackItem(title: "国语", tag: 5)
        let third = popup.appendTrackItem(title: "国语", tag: 9)

        #expect(popup.numberOfItems == 3)
        #expect(popup.itemArray.map(\.tag) == [2, 5, 9])
        #expect(popup.itemArray[0] === first)
        #expect(popup.itemArray[1] === second)
        #expect(popup.itemArray[2] === third)
        #expect(popup.selectItem(withTag: 5))
        #expect(popup.indexOfSelectedItem == 1)
        #expect(popup.selectedItem === second)
        popup.selectItem(at: 2)
        #expect(popup.selectedItem?.tag == 9)
        let receiver = TrackActionReceiver()
        popup.target = receiver
        popup.action = #selector(TrackActionReceiver.changed(_:))
        popup.menu?.performActionForItem(at: 1)
        #expect(receiver.selectedTag == 5, "Native menu actions must still reach the popup's target")
    }

    @Test
    func duplicateSubtitlesPreserveChoiceIndexesAcrossRebuilds() {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        func rebuild() {
            popup.removeAllItems()
            popup.appendTrackItem(title: "字幕：关闭", tag: 0)
            popup.appendTrackItem(title: "chs&eng", tag: 1)
            popup.appendTrackItem(title: "chs&eng", tag: 2)
            popup.appendTrackItem(title: "chs", tag: 3)
        }
        rebuild()
        #expect(popup.itemTitles == ["字幕：关闭", "chs&eng", "chs&eng", "chs"])
        popup.selectItem(at: 3)
        #expect(popup.selectedItem?.tag == 3)
        #expect(popup.selectedItem?.title == "chs")
        rebuild()
        #expect(popup.selectItem(withTag: 3))
        #expect(popup.indexOfSelectedItem == 3)
        #expect(popup.selectedItem?.title == "chs")
        popup.selectItem(at: 2)
        #expect(popup.selectedItem?.tag == 2)
        #expect(popup.selectedItem?.title == "chs&eng")
    }

    @Test
    func createsMissingMenuAndPreservesAllThreeIdenticalSubtitles() {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.menu = nil
        popup.appendTrackItem(title: "中文字幕", tag: 4)
        popup.appendTrackItem(title: "中文字幕", tag: 6)
        popup.appendTrackItem(title: "中文字幕", tag: 8)
        #expect(popup.menu != nil)
        #expect(popup.numberOfItems == 3)
        #expect(popup.itemArray.map(\.tag) == [4, 6, 8])
        popup.selectItem(at: 2)
        #expect(popup.selectedItem?.tag == 8)
    }
}

@MainActor
private final class TrackActionReceiver: NSObject {
    var selectedTag: Int?
    @objc func changed(_ sender: NSPopUpButton) { selectedTag = sender.selectedItem?.tag }
}
