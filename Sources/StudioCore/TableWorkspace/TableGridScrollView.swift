import AppKit

/// Reserve a fixed header band. Recent AppKit versions tile the document clip
/// beneath NSTableHeaderView, even with zero scroll-view content insets.
final class TableGridScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let table = documentView as? NSTableView, let header = table.headerView,
              header.superview != nil else { return }
        let headerFrame = header.convert(header.bounds, to: self)
        var bodyFrame = contentView.frame
        let overlap = bodyFrame.intersection(headerFrame)
        guard !overlap.isNull, overlap.height > 0 else { return }
        if headerFrame.midY < bodyFrame.midY {
            let bottom = bodyFrame.maxY
            bodyFrame.origin.y = headerFrame.maxY
            bodyFrame.size.height = max(0, bottom - bodyFrame.minY)
        } else {
            bodyFrame.size.height = max(0, headerFrame.minY - bodyFrame.minY)
        }
        contentView.frame = bodyFrame
        contentView.contentInsets = NSEdgeInsetsZero
        contentView.clipsToBounds = true
    }
}
