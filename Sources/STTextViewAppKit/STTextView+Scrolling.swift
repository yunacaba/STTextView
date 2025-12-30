//  Created by Marcin Krzyzanowski
//  https://github.com/krzyzanowskim/STTextView/blob/main/LICENSE.md


import AppKit

private let scrollLogEnabled = ProcessInfo().environment["ST_SCROLL_LOG"] == "YES"

private func scrollLog(_ message: @autoclosure () -> String) {
    if scrollLogEnabled {
        print("[SCROLL] \(message())")
    }
}

extension STTextView {

    override open func scroll(_ point: NSPoint) {
        scrollLog("scroll(\(point)) - applying gutter offset \(gutterView?.frame.width ?? 0)")
        contentView.scroll(point.applying(.init(translationX: -(gutterView?.frame.width ?? 0), y: 0)))
    }

    @discardableResult
    func scrollToVisible(_ textRange: NSTextRange, type: NSTextLayoutManager.SegmentType) -> Bool {
        guard var rect = textLayoutManager.textSegmentFrame(in: textRange, type: type) else {
            scrollLog("scrollToVisible - no textSegmentFrame for range")
            return false
        }

        scrollLog("scrollToVisible - original rect: \(rect)")

        if rect.width.isZero {
            // add padding around the point to ensure the visibility the segment
            // since the width of the segment is 0 for a selection
            rect = rect.inset(by: .init(top: 0, left: -textContainer.lineFragmentPadding, bottom: 0, right: -textContainer.lineFragmentPadding))
        }

        // scroll to visible IN clip view (ignoring gutter view overlay)
        // adjust rect to mimick it's size to include gutter overlay
        rect.origin.x -= gutterView?.frame.width ?? 0
        rect.size.width += gutterView?.frame.width ?? 0

        scrollLog("scrollToVisible - adjusted rect: \(rect), contentView.frame: \(contentView.frame)")
        scrollLog("scrollToVisible - contentView.enclosingScrollView: \(String(describing: contentView.enclosingScrollView))")
        scrollLog("scrollToVisible - self.scrollView: \(String(describing: scrollView))")

        let result = contentView.scrollToVisible(rect)
        scrollLog("scrollToVisible -> \(result)")
        return result
    }

    override open func centerSelectionInVisibleArea(_ sender: Any?) {
        guard let selectionTextRange = textLayoutManager.textSelections.last?.textRanges.last,
              var rect = textLayoutManager.textSegmentFrame(in: selectionTextRange, type: .selection) else {
            return
        }

        if rect.width.isZero {
            // add padding around the point to ensure the visibility the segment
            // since the width of the segment is 0 for a selection
            rect = rect.inset(by: .init(top: 0, left: -textContainer.lineFragmentPadding, bottom: 0, right: -textContainer.lineFragmentPadding))
        }

        // scroll to visible IN clip view (ignoring gutter view overlay)
        // adjust rect to mimick it's size to include gutter overlay
        rect.origin.x -= gutterView?.frame.width ?? 0
        rect.size.width += gutterView?.frame.width ?? 0

        // put rect origin in the center
        contentView.scroll(rect.origin.applying(.init(translationX: 0, y: -visibleRect.height / 2)))
    }

    override open func pageUp(_ sender: Any?) {
        scrollPageUp(sender)
    }

    override open func pageUpAndModifySelection(_ sender: Any?) {
        pageUp(sender)
    }

    override open func pageDown(_ sender: Any?) {
        scrollPageDown(sender)
    }

    override open func pageDownAndModifySelection(_ sender: Any?) {
        pageDown(sender)
    }

    override open func scrollPageDown(_ sender: Any?) {
        scroll(visibleRect.moved(dy: visibleRect.height).origin)
    }

    override open func scrollPageUp(_ sender: Any?) {
        scroll(visibleRect.moved(dy: -visibleRect.height).origin)
    }

    override open func scrollToBeginningOfDocument(_ sender: Any?) {
        scroll(CGPoint(x: visibleRect.origin.x, y: frame.minY))
    }

    override open func scrollToEndOfDocument(_ sender: Any?) {
        relocateViewport(to: textLayoutManager.documentRange.endLocation)
        scroll(CGPoint(x: visibleRect.origin.x, y: frame.maxY))
    }
}
