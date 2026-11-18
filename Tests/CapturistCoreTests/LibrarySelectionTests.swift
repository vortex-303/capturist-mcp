import Foundation
import Testing
@testable import CapturistCore

@Suite("Library selection")
struct LibrarySelectionTests {
    let order = (0..<6).map { _ in UUID() }

    @Test("plain click selects one item")
    func plainClick() {
        var s = LibrarySelection()
        s.click(order[1], in: order)
        s.click(order[3], in: order)
        #expect(s.ids == [order[3]])
        #expect(s.focus == order[3])
    }

    @Test("shift-click selects the range from the anchor, in either direction")
    func shiftRange() {
        var s = LibrarySelection()
        s.click(order[1], in: order)
        s.click(order[4], in: order, shift: true)
        #expect(s.ids == Set(order[1...4]))
        // Shift again re-ranges from the same anchor (Finder behaviour).
        s.click(order[0], in: order, shift: true)
        #expect(s.ids == Set(order[0...1]))
        #expect(s.anchor == order[1])
    }

    @Test("command-click toggles single items")
    func commandToggle() {
        var s = LibrarySelection()
        s.click(order[0], in: order)
        s.click(order[2], in: order, command: true)
        s.click(order[5], in: order, command: true)
        #expect(s.ids == [order[0], order[2], order[5]])
        s.click(order[2], in: order, command: true)
        #expect(s.ids == [order[0], order[5]])
    }

    @Test("command-shift adds a range to the selection")
    func commandShift() {
        var s = LibrarySelection()
        s.click(order[0], in: order)
        s.click(order[3], in: order, command: true)
        s.click(order[5], in: order, shift: true, command: true)
        #expect(s.ids == [order[0], order[3], order[4], order[5]])
    }

    @Test("select all and prune after delete")
    func selectAllAndPrune() {
        var s = LibrarySelection()
        s.selectAll(order)
        #expect(s.count == 6)
        s.prune(to: Array(order[3...]))
        #expect(s.ids == Set(order[3...]))
        #expect(s.focus == order[3])
    }
}
