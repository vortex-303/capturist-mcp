import Foundation

/// Finder-style multi-selection for the library grid.
/// - click: select only that item (it becomes the anchor)
/// - shift-click: select the range from the anchor to the clicked item
/// - ⌘-click: add or remove one item
/// - ⌘⇧-click: add the range to the current selection
public struct LibrarySelection: Equatable, Sendable {
    public private(set) var ids: Set<UUID> = []
    /// Start of shift-click ranges.
    public private(set) var anchor: UUID?
    /// Last clicked item; shown in the detail pane when exactly one item is selected.
    public private(set) var focus: UUID?

    public init() {}

    public var count: Int { ids.count }
    public func contains(_ id: UUID) -> Bool { ids.contains(id) }

    public mutating func select(_ id: UUID?) {
        ids = id.map { [$0] } ?? []
        anchor = id
        focus = id
    }

    public mutating func click(_ id: UUID, in order: [UUID], shift: Bool = false, command: Bool = false) {
        if shift, let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            let range = Set(order[min(from, to)...max(from, to)])
            ids = command ? ids.union(range) : range
            focus = id
        } else if command {
            if ids.contains(id) {
                ids.remove(id)
                if focus == id { focus = order.last(where: ids.contains) }
                if anchor == id { anchor = focus }
            } else {
                ids.insert(id)
                anchor = id
                focus = id
            }
        } else {
            select(id)
        }
    }

    public mutating func selectAll(_ order: [UUID]) {
        ids = Set(order)
        anchor = order.first
        focus = order.first
    }

    /// Drops ids that are no longer listed (after delete, filter or search).
    public mutating func prune(to order: [UUID]) {
        let visible = Set(order)
        ids.formIntersection(visible)
        if let anchor, !visible.contains(anchor) { self.anchor = order.first(where: ids.contains) }
        if let focus, !visible.contains(focus) { self.focus = order.first(where: ids.contains) }
    }
}
