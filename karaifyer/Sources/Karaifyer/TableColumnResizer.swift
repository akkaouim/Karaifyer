import AppKit
import SwiftUI

/// SwiftUI's Table lays its columns out once: a width change in code only shows after a manual resize. This finds
/// the window's table column whose title starts with `titlePrefix` and sets its width directly, keeping the
/// scroll position (rebuilding the Table would jump back to the top).
struct TableColumnResizer: NSViewRepresentable {
    let titlePrefix: String
    let width: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let prefix = titlePrefix, w = width
        DispatchQueue.main.async {            // after SwiftUI has applied the new header title
            guard let root = view.window?.contentView else { return }
            for table in Self.tables(in: root) {
                for column in table.tableColumns where column.title.hasPrefix(prefix) && abs(column.width - w) > 0.5 {
                    column.minWidth = min(column.minWidth, w)
                    column.width = w
                }
            }
        }
    }

    static func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }
}
